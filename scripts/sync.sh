#!/usr/bin/env bash

#####################################
readonly SELF="${0##*/}"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"  # location of this script
JOB_ID="sync-$$"
#####################################

is_upstream_removed() {
    local local_node remote_node
    local_node="$1"

    [[ "$local_node" == */* ]] && fail "passed local node should not contain slashes: [$local_node]"

    for remote_node in "${REMOTE_NODES[@]}"; do
        [[ "$remote_node" == */* ]] && fail "remote node should not contain slashes: [$remote_node]"
        [[ "$remote_node" == "$local_node" ]] && return 1
    done

    return 0  # no match, hence asset has been removed on remote
}


#### ENTRY
source /common.sh || { echo -e "    ERROR: failed to import /common.sh"; exit 1; }

_prepare_locking
exlock_now || { info "unable to obtain lock: $?"; exit 0; }

validate_config_common
check_connection || fail "no internets"

REMOTE_NODES=()
ADD_FILTER=()
TO_DOWNLOAD_LIST=()

if [[ -n "${RCLONE_FLAGS[*]}" ]]; then
    IFS="$SEPARATOR" read -ra RCLONE_FLAGS <<< "$RCLONE_FLAGS"
else  # no rclone flags provided, define our set of defaults;
    # note if your seedbox had an nvme or a dedicated disk plan, then there
    # would be no need for bwlimit
    RCLONE_FLAGS=(
      --config "$RCLONE_CONF"
      --fast-list
      --bwlimit 20M
      --use-mmap
      --transfers 10
    )
fi

if [[ -n "${RCLONE_OPTS[*]}" ]]; then
    IFS="$SEPARATOR" read -ra rclone_opts <<< "$RCLONE_OPTS"
    RCLONE_FLAGS+=("${rclone_opts[@]}")   # allow extending w/ user-provided opts
fi

# non-empty $DEST_INITIAL suggests issues during previous run(s):
is_dir_empty "$DEST_INITIAL" || err "expected DEST_INITIAL dir [$DEST_INITIAL] to be empty, but it's not"

# move assets _to_ remote (.torrent files to watchdir):
if [[ -d "$WATCHDIR_SRC" ]] && ! is_dir_empty "$WATCHDIR_SRC"; then
    rclone move --log-file "$LOG_ROOT/rclone-move.log" "${RCLONE_FLAGS[@]}" \
            "$WATCHDIR_SRC" "$REMOTE:$WATCHDIR_DEST" || err "rclone move from [$WATCHDIR_SRC] to [$WATCHDIR_DEST] failed w/ $?"  # TODO: pushover! but do _not_ fail out here
fi

# first list the remote source dir contents:
remote_nodes="$(rclone lsf --log-file "$LOG_ROOT/rclone-lsf.log" \
    "${RCLONE_FLAGS[@]}" -- "$REMOTE:$SRC_DIR")" || fail "rclone lsf failed w/ $?"  # TODO: pushover!
readarray -t remote_nodes <<< "$remote_nodes"

# ...then verify which assets we haven't already downloaded-processed, and compile
# them into rclone '--filter' options:
for f in "${remote_nodes[@]}"; do
    REMOTE_NODES+=("${f%/}")  # note we remove possible trailing slash
    [[ -e "$DEST_FINAL/${f%/}" ]] && continue  # already been processed
    TO_DOWNLOAD_LIST+=("$f")
    ADD_FILTER+=('--filter')
    f_escaped="$(sed 's/[.\*^$()+?{}|]/\\&/g;s/[][]/\\&/g' <<< "$f")"
    [[ "$f_escaped" == */ ]] && ADD_FILTER+=("+ /${f_escaped}**") || ADD_FILTER+=("+ /$f_escaped")
done

# ...nuke assets that are already removed on the remote:
if [[ -z "$SKIP_LOCAL_RM" ]]; then
    while IFS= read -r -d $'\0' f; do
        if is_upstream_removed "$(basename -- "$f")"; then
            rm -rf -- "$f" \
                    && info "removed [$f] whose remote counterpart is gone" \
                    || err "[rm -rf $f] failed w/ $?"
        fi
    done< <(find -L "$DEST_FINAL" -mindepth 1 -maxdepth 1 -print0)
fi

# pull new assets:
if [[ "${#TO_DOWNLOAD_LIST[@]}" -gt 0 ]]; then
    [[ "${#TO_DOWNLOAD_LIST[@]}" -gt 1 ]] && s=s
    info "going to copy following ${#TO_DOWNLOAD_LIST[@]} node${s} from remote:"
    unset s

    for i in "${TO_DOWNLOAD_LIST[@]}"; do
        info "  > $i"
    done

    rclone copy --log-file "$LOG_ROOT/rclone-copy.log" "${RCLONE_FLAGS[@]}" \
        "$REMOTE:$SRC_DIR" "$DEST_INITIAL" "${ADD_FILTER[@]}" --filter '- *' || fail "rclone copy failed w/ $?"  # TODO: pushover!
fi

# process assets.
# note we work on _all_ nodes in $DEST_INITIAL, not only ones
# that were pulled during this execution; this is essentially
# for retrying previous failures:
while IFS= read -r -d $'\0' f; do
    if [[ -z "$SKIP_EXTRACT" && ! -e "$DEST_FINAL/$SKIP_EXTRACT_MARKER_FILE" ]]; then
        extract.sh "$f" || { err "[$f] extraction failed"; continue; }  # TODO: pushover!
    fi

    if [[ -e "$DEST_FINAL/$(basename -- "$f")" ]]; then
        err "[$DEST_FINAL/$(basename -- "$f")] already exists; cannot move [$f] into $DEST_FINAL"  # TODO: pushover!
        continue
    else
        mv -- "$f" "$DEST_FINAL/" || { err "[mv $f $DEST_FINAL/] failed w/ $?"; continue; }  # TODO: pushover!
    fi
done< <(find -L "$DEST_INITIAL" -mindepth 1 -maxdepth 1 -print0)

exit 0
