
#!/usr/bin/env bash
#
# data.sh – Datamosh workflow with command-line options

set -euo pipefail

# ---------- Helper functions ----------
print_help() {
    cat <<EOF
Usage: $(basename "$0") [options]

Required arguments:
  -a, --clip-a FILE          First (source) video.
  -b, --clip-b FILE          Second (target) video.
  -o, --output FILE          Final output filename.

Optional arguments:
  -r, --resolution WxH      Output resolution (default: 1920x1080).
  -f, --fps N                Frame rate (default: 30).
  -c, --crf N                Quality (default: 18).
  -k, --keyint N             Max distance between I-frames (default: 999).
  -g, --gop N                GOP size for first clip (default: 999).
  -q, --audio-a FILE         Audio track for clip A (optional).
  -Q, --audio-b FILE         Audio track for clip B (optional).
  -t, --temp-dir DIR         Directory for intermediate files (default: ./tmp_datamosh).
  -p, --preset PRESET        x264 preset (default: veryfast).
  -h, --help                 Show this help message and exit.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# ---------- Default values ----------
declare -A opt=(
    [resolution]="1920x1080"
    [fps]="30"
    [crf]="18"
    [keyint]="999"
    [gop]="999"
    [preset]="veryfast"
    [tempdir]="./tmp_datamosh"
)

# ---------- Parse arguments ----------
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
        -h|--help)     print_help; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ---------- Validate required args ----------
[[ -z "${opt[clip_a]:-}" ]] && die "Missing required argument: --clip-a"
[[ -z "${opt[clip_b]:-}" ]] && die "Missing required argument: --clip-b"
[[ -z "${opt[output]:-}" ]] && die "Missing required argument: --output"

# ---------- Create temporary working directory ----------
TMP="${opt[tempdir]}"
mkdir -p "$TMP"

set -x

# ---------- Step 1: Assemble clips into one video ----------
echo "Assembling clips into original_video.mp4..."
input_txt="$TMP/input.txt"
abs_a="$(realpath "${opt[clip_a]}")"
abs_b="$(realpath "${opt[clip_b]}")"
echo "file '$abs_a'" > "$input_txt"
echo "file '$abs_b'" >> "$input_txt"
ffmpeg -y -f concat -safe 0 -i "$input_txt" -c copy "$TMP/original_video.mp4" 1>/dev/null 2>&1

# ---------- Step 2: Convert to Xvid AVI with long GOP ----------
ffmpeg -y -i "$TMP/original_video.mp4" -vcodec libxvid -q:v 1 -g "${opt[keyint]}" -qmin 1 -qmax 1 -flags +qpel+mv4 -an "$TMP/xvid_video.avi" 1>/dev/null 2>&1

# ---------- Step 3: Extract raw frames and images ----------
mkdir -p frames/save images
echo "Extracting raw frames as .raw files..."
ffmpeg -y -i "$TMP/xvid_video.avi" -vcodec copy -start_number 0 frames/f_%04d.raw 1>/dev/null 2>&1
echo "Extracting frame images to images/..."
ffmpeg -y -i "$TMP/xvid_video.avi" -start_number 0 images/i_%04d.jpg 1>/dev/null 2>&1

# ---------- Step 4: Identify I-frame numbers ----------
echo "Identifying I-frame numbers..."
ffprobe -v error -select_streams v:0 -show_entries frame=pict_type -of csv "$TMP/xvid_video.avi" > "$TMP/pict_types.csv" 2>/dev/null
iframe_numbers=()
idx=0
while IFS= read -r line; do
    let idx+=1
    if [[ "$line" == "frame,I" ]]; then
        iframe_numbers+=("$idx")
    fi
done < "$TMP/pict_types.csv"

echo "I-frame numbers (excluding first): ${iframe_numbers[@]:1}"

# ---------- Step 5: Remove I-frames (except first), replace with next frame ----------
echo "Removing I-frames and replacing with next frame..."
for iframe_number in "${iframe_numbers[@]:1}"; do
    src=$(printf "frames/f_%04d.raw" $((iframe_number-1)))
    next=$(printf "frames/f_%04d.raw" $iframe_number)
    if [[ -f "$src" && -f "$next" ]]; then
        mv "$src" "frames/save/$(basename "$src")"
        cp "$next" "$src"
    fi
done

# ---------- Step 6: Concatenate raw frames into edited_video.avi ----------
echo "Concatenating raw frames into edited_video.avi..."
ls frames/f_*.raw | sort -V > "$TMP/rawlist.txt"
cat $(cat "$TMP/rawlist.txt") > "$TMP/edited_video.avi"

# ---------- Step 7: Add audio back and scale final video ----------
scale_option="scale=trunc(iw/2)*2:trunc(ih/2)*2"

ffmpeg -y -i "$TMP/edited_video.avi" -i "$TMP/original_video.mp4" -vf "$scale_option" -map 0:v:0 -map 1:a:0 -vcodec h264 -shortest "${opt[output]}" 1>/dev/null 2>&1

# clean up temporary files
rm -rf "$TMP"

echo "Processing complete! Final video is ${opt[output]}"