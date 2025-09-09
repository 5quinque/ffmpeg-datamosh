#!/usr/bin/env bash
# main.sh – CLI entry point for datamosh workflow

set -euo pipefail
source "$(dirname "$0")/lib/datamosh_lib.sh"

# ---------- Parse arguments ----------
declare -A opt=(
    [resolution]="1920x1080"
    [fps]="30"
    [crf]="18"
    [keyint]="999"
    [gop]="999"
    [preset]="veryfast"
    [tempdir]="./tmp_datamosh"
)

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--clip-a)   opt[clip_a]="$2"; shift 2 ;;
        -b|--clip-b)   opt[clip_b]="$2"; shift 2 ;;
        -o|--output)   opt[output]="$2"; shift 2 ;;
        -r|--resolution) opt[resolution]="$2"; shift 2 ;;
        -f|--fps)      opt[fps]="$2"; shift 2 ;;
        -c|--crf)      opt[crf]="$2"; shift 2 ;;
        -k|--keyint)   opt[keyint]="$2"; shift 2 ;;
        -g|--gop)      opt[gop]="$2"; shift 2 ;;
        -q|--audio-a)  opt[audio_a]="$2"; shift 2 ;;
        -Q|--audio-b)  opt[audio_b]="$2"; shift 2 ;;
        -t|--temp-dir) opt[tempdir]="$2"; shift 2 ;;
        -p|--preset)   opt[preset]="$2"; shift 2 ;;
        -h|--help)     echo "Usage: ..."; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "${opt[clip_a]:-}" ]] && { echo "Missing required argument: --clip-a"; exit 1; }
[[ -z "${opt[clip_b]:-}" ]] && { echo "Missing required argument: --clip-b"; exit 1; }
[[ -z "${opt[output]:-}" ]] && { echo "Missing required argument: --output"; exit 1; }

main() {
    set -x
    TMP="${opt[tempdir]}"
    mkdir -p "$TMP"

    FIRST_CLIP=$(split_clip_at_last_keyframe "${opt[clip_a]}" $TMP)
    SECOND_CLIP=$(split_clip "${opt[clip_b]}" $TMP 2)

    FIRST_CLIP_A=$(echo "$FIRST_CLIP" | cut -d' ' -f1)
    FIRST_CLIP_B=$(echo "$FIRST_CLIP" | cut -d' ' -f2)
    SECOND_CLIP_A=$(echo "$SECOND_CLIP" | cut -d' ' -f1)
    SECOND_CLIP_B=$(echo "$SECOND_CLIP" | cut -d' ' -f2)

    assemble_clips "$TMP/concat.mp4" "$FIRST_CLIP_B" "$SECOND_CLIP_A"
    convert_to_xvid "$TMP/concat.mp4" "${opt[keyint]}" "$TMP/xvid.avi"
    extract_frames_and_images "$TMP/xvid.avi"
    identify_iframes "$TMP/xvid.avi" "$TMP/pict_types.csv"
    iframe_numbers=()
    get_iframe_numbers "$TMP/pict_types.csv" iframe_numbers
    remove_iframes $TMP iframe_numbers
    concat_raw_frames "$TMP" "$TMP/edited_video.avi"

    scale_option="scale=trunc(iw/2)*2:trunc(ih/2)*2"

    finalize_video "$TMP/edited_video.avi" "$TMP/concat.mp4" "$TMP/mosh.mp4" "$scale_option"

    assemble_clips_reencoded "${opt[output]}" "$FIRST_CLIP_A" "$TMP/mosh.mp4" "$SECOND_CLIP_B"

    # rm -rf "$TMP"
    # echo "Processing complete! Final video is ${opt[output]}"
}

main "$@"
