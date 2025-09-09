#!/usr/bin/env bash
# datamosh_lib.sh – All datamosh workflow functions

set -euo pipefail


split_clip_at_last_keyframe() {
    local clip="$1"
    local out_dir="$2"

    # ------------------------------------------------------------------
    # Basic validation
    # ------------------------------------------------------------------
    [[ -f "$clip" ]]   || { echo "Error: input file not found." >&2; return 1; }
    [[ -d "$out_dir" ]]|| { echo "Error: output directory does not exist." >&2; return 1; }

    # ------------------------------------------------------------------
    # Normalise the base filename (strip extension)
    # ------------------------------------------------------------------
    local filename
    filename="$(basename "$clip")"
    filename="${filename%.*}"               # remove .ext

    local out_a="${out_dir}/${filename}_part_a.mp4"
    local out_b="${out_dir}/${filename}_part_b.mp4"

    # ------------------------------------------------------------------
    # Find the timestamp of the **last** keyframe (I‑frame) in the video
    # ------------------------------------------------------------------
    # ffprobe outputs CSV lines: frame,<type>,<pts_time>,…
    # We keep only I‑frames and grab the timestamp of the final one.
    local last_keyframe_time
    last_keyframe_time=$(ffprobe -v error -select_streams v:0 -show_frames -print_format csv -show_entries frame=pict_type,pts_time "$clip" | grep I$ | tail -n 1 | cut -d',' -f2)

    # If the video somehow contains no I‑frames (very rare), fall back to 0.
    [[ -z "$last_keyframe_time" ]] && last_keyframe_time=0

    # ------------------------------------------------------------------
    # Perform the split using stream copy (no re‑encoding)
    # ------------------------------------------------------------------
    # Part A – from start up to the last keyframe
    ffmpeg -y -hide_banner -loglevel error -i "$clip" \
           -to "$last_keyframe_time" -c copy "$out_a"
    if [[ $? -ne 0 ]]; then
        echo "Error: failed to create $out_a" >&2
        return 1
    fi

    # Part B – from the last keyframe to the end
    ffmpeg -y -hide_banner -loglevel error -i "$clip" \
           -ss "$last_keyframe_time" -c copy "$out_b"
    if [[ $? -ne 0 ]]; then
        echo "Error: failed to create $out_b" >&2
        return 1
    fi

    # Success – echo the two output file paths
    echo "$out_a $out_b"
}

split_clip() {
    local clip="$1"
    local out_dir="$2"

    local filename=$(basename "$clip")
    local filename="${filename%.*}"

    local out_a="$out_dir/${filename}_part_a.mp4"
    local out_b="$out_dir/${filename}_part_b.mp4"

    local time="$3"

    # time is in the format seconds. float. Positive number is seconds from start,
    # negative number is seconds from end.
    if (( $(echo "$time < 0" | bc -l) )); then
        duration=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of csv=p=0 "$clip")
        time=$(awk "BEGIN {print $duration + $time}")
    fi
    ffmpeg -y -i "$clip" -t "$time" -c copy "$out_a" 1>/dev/null 2>&1
    ffmpeg -y -i "$clip" -ss "$time" -c copy "$out_b" 1>/dev/null 2>&1

    echo "$out_a $out_b"
}

# Split a clip at the nearest keyframe to the given time
split_clip_on_keyframe() {
    local clip="$1"
    local out_dir="$2"
    local time="$3"

    local filename=$(basename "$clip")
    local filename="${filename%.*}"
    local out_a="$out_dir/${filename}_part_a.mp4"
    local out_b="$out_dir/${filename}_part_b.mp4"

    # Adjust time if negative
    if (( $(echo "$time < 0" | bc -l) )); then
        duration=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of csv=p=0 "$clip")
        time=$(awk "BEGIN {print $duration + $time}")
    fi

    # Find nearest keyframe before or at time

    local keyframe_time
    keyframe_time=$(ffprobe -v error -select_streams v:0 \
                            -show_entries frame=pict_type,pkt_pts_time \
                            -of csv=p=0 "$clip" |
                    awk -F',' -v t="$time" '$1 == "frame" && $2 == "I" && $3 <= t { last = $3 } END { print (last == "" ? 0 : last) }')    

    # keyframe_time=$(ffprobe -v error -select_streams v:0 -show_frames -print_format csv -show_entries frame=pict_type,pts_time "$clip" \
    #     | awk -F',' -v t="$time" '$2=="I" && $3 <= t {last=$3} END{print last}')
    # if [[ -z "$keyframe_time" ]]; then
    #     keyframe_time=0
    # fi

    # Split at keyframe
    ffmpeg -y -i "$clip" -t "$keyframe_time" -c copy "$out_a" 1>/dev/null 2>&1
    ffmpeg -y -i "$clip" -ss "$keyframe_time" -c copy "$out_b" 1>/dev/null 2>&1

    echo "$out_a $out_b"
}



assemble_clips() {
    local out_mp4="$1"
    local out_dir="$(dirname "$out_mp4")"
    shift
    local input_txt="$out_dir/input.txt"
    > "$input_txt"
    for clip in "$@"; do
        local abs_clip="$(realpath "$clip")"
        echo "file '$abs_clip'" >> "$input_txt"
    done
    ffmpeg -y -f concat -safe 0 -i "$input_txt" -c copy "$out_mp4" 1>/dev/null 2>&1
}

assemble_clips_reencoded() {
    local out_mp4="$1"
    local out_dir="$(dirname "$out_mp4")"
    shift
    local input_txt="$out_dir/input.txt"
    local reenc_dir="$out_dir/reencoded"
    mkdir -p "$reenc_dir"
    > "$input_txt"
    local i=0
    for clip in "$@"; do
        local abs_clip="$(realpath "$clip")"
        local reenc_clip="$reenc_dir/clip_$i.mp4"
        ffmpeg -y -i "$abs_clip" -c:v libx265 -preset veryfast -crf 18 -force_key_frames "expr:gte(t,n_forced*1)" -c:a copy "$reenc_clip" 1>/dev/null 2>&1
        echo "file '$reenc_clip'" >> "$input_txt"
        i=$((i+1))
    done
    ffmpeg -y -f concat -safe 0 -i "$input_txt" -c copy "$out_mp4" 1>/dev/null 2>&1
}

convert_to_xvid() {
    local in_mp4="$1"
    local keyint="$2"
    local out_avi="$3"
    ffmpeg -y -i "$in_mp4" -vcodec libxvid -q:v 1 -g "$keyint" -qmin 1 -qmax 1 -flags +qpel+mv4 -an "$out_avi" 1>/dev/null 2>&1
}

extract_frames_and_images() {
    local in_avi="$1"
    local tmp_dir="$(dirname "$in_avi")"
    mkdir -p "$tmp_dir/frames/save" "$tmp_dir/images"
    ffmpeg -y -i "$in_avi" -vcodec copy -start_number 0 "$tmp_dir/frames/f_%04d.raw" 1>/dev/null 2>&1
    ffmpeg -y -i "$in_avi" -start_number 0 "$tmp_dir/images/i_%04d.jpg" 1>/dev/null 2>&1
}

identify_iframes() {
    local in_avi="$1"
    local out_csv="$2"
    ffprobe -v error -select_streams v:0 -show_entries frame=pict_type -of csv "$in_avi" > "$out_csv"
}

get_iframe_numbers() {
    local csv="$1"
    local -n arr=$2
    local idx=0
    while IFS= read -r line; do
        let idx+=1
        if [[ "$line" == "frame,I" ]]; then
            arr+=("$idx")
        fi
    done < "$csv"
}

remove_iframes() {
    local tmp_dir="$1"
    local -n iframe_numbers=$2
    for iframe_number in "${iframe_numbers[@]:1}"; do
        src=$(printf "$tmp_dir/frames/f_%04d.raw" $((iframe_number-1)))
        next=$(printf "$tmp_dir/frames/f_%04d.raw" $iframe_number)
        if [[ -f "$src" && -f "$next" ]]; then
            mv "$src" "$tmp_dir/frames/save/$(basename "$src")"
            cp "$next" "$src"
        fi
    done
}

concat_raw_frames() {
    local out_dir="$1"
    local out_avi="$2"
    ls $out_dir/frames/f_*.raw | sort -V > "$out_dir/rawlist.txt"
    cat $(cat "$out_dir/rawlist.txt") > "$out_avi"
}

finalize_video() {
    local in_avi="$1"
    local in_mp4="$2"
    local output="$3"
    # -vf "$scale_option" 
    # local scale_option="$4"
    ffmpeg -y -i "$in_avi" -i "$in_mp4" -map 0:v:0 -map 1:a:0 -vcodec copy -shortest "$output" 1>/dev/null 2>&1
}
