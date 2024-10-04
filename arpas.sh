#!/bin/sh

# Enable debugging mode.
#set -x

#################################################################################
# Description:	This script remove from media files unnecessary audio and		#
#	subtitles also converts not supported audio codecs and renames files.		#
# Author: [remigijus.gaigalas@gmail.com]										#
# Date: [2024-09-28]															#
# Version: [0.7.2]																#
#################################################################################


# Define constants.
# Change them to best suite you.
DEFAULT_SOURCE="/media/remigijus/Games2/mkv/" # Default source for movie or TV series. Can be file or directory. Used when not set source.
DEFAULT_DESTINATION="/mnt/Duomenys/Aruodas/Filmai4/Drama/" # Default destination for movie. Can be directory. Used when not set destination.
DEFAULT_TV_SERIES_DESTINATION="/mnt/Duomenys/Aruodas/Filmai4/Turimi/Serijalai/" # Default TV series directory. Used when not set destination.
LANGUAGES="lit eng rus"	# Preferred and fallback languages. Script chooses languages from left to right.
CONVERT_AUDIO_CODEC="libvorbis" # Audio codec to convert unsupported codecs.
EXTENSIONS=".mkv .mka .mp4 .m2ts .avi" # Script supported file extensions.
SUPPORTED_VIDEO_CODECS="h264 hevc av1 vp8 vp9" # Convert audio with these video codecs.
SUPPORTED_AUDIO_CODECS="vorbis aac mp3 opus flac" # Do not convert audio with these audio codecs.

# Define Global variables.
# Please do not change.
total_diff=0 # Global variable to keep track of total file size difference.
errors="" # Global variable to keep track files with conversation errors.
messages_without_mistakes="" # Global variable to keep track files without conversation errors.
size_difference=0 # Difference in bytes between source and destination files.
create_directory_choice="" # Store the user's choice of directory creation.
copy_file_choice="" # Store the user's choice of file copy creation.
execution_time=0 # Time to complete FFmpeg command

# Function to check if a file has a valid extension.
is_valid_file() {
#	echo "$1"
	file_extension=".${1##*.}"
	for ext in $EXTENSIONS; do
		if [ "$ext" = "$file_extension" ]; then
			return 0 # Valid extension found.
		fi
	done
	return 1 # No valid extension found.
}

# Function to check if the package is installed.
checkpackage(){
if ! command -v "$1" > /dev/null 2>&1; then
	echo "Error: $1 package is not installed. Please install it first."
	exit 1
fi
}

# Function to convert bytes to human readable form.
human_readable_size(){
	SIZE="$1" # input size in bytes
	UNITS="B KiB MiB GiB TiB PiB" # list of unit prefixes

	# Iterate through the units, starting from the smallest and working our way up
	for UNIT in $UNITS; do
		test "${SIZE%.*}" -lt 1024 && break;

		# Divide the size by 1024 to get a new value for the next unit
		SIZE=$(awk "BEGIN {printf \"%.2f\",${SIZE}/1024}")
	done

	# if the unit is still "B" at this point, it means we've already converted the size to bytes. 
	# In that case, just print the size with a single space before the unit.
	if [ "$UNIT" = "B" ]; then
		printf "%4.0f %s\n" "$SIZE" "$UNIT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
	else
		printf "%7.02f %s\n" "$SIZE" "$UNIT "| sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
	fi
}

# Function to convert a file.
convert_file(){
	source="$1"
	destination="$2"
	destination_directory="$2"

	if is_valid_file "$source"; then
		#echo "Converting ${source#$source_directory/} Please wait ..."
		# Make destination file name from destination path and source file name.
		extension=$(echo "$source" | awk -F. '{print $NF}')
		source_file_name=$(basename "$source")
		source_file_name="${source_file_name%.*}" # Without extension.
		pattern="([Ss])([0-9]+)[._ -]?([Ee])([0-9]+)"
		# Regular expression to match various TV series patterns
		series_pattern=$(echo "$source_file_name" | grep -Eo "$pattern")

		if [ -n "$series_pattern" ]; then
			normalized_series=""
			for pattern in $series_pattern;do
				# If TV series pattern found, normalize it to the "S01E01" format.
				season=$(echo "$pattern" | sed -E 's/[^0-9]*([0-9]+)[^0-9]+([0-9]+)/\1/')
				episode=$(echo "$pattern" | sed -E 's/[^0-9]*([0-9]+)[^0-9]+([0-9]+)/\2/')
				# Remove leading zeros from season and episode variables.
				season=$(echo "$season" | sed 's/^0*//')
				episode=$(echo "$episode" | sed 's/^0*//')
				normalized_series="$(printf "$normalized_series")S$(printf "%02d" "$season")E$(printf "%02d" "$episode")"
			done
			#echo "DEFAULT_DESTINATION=$DEFAULT_DESTINATION"
			if [ "$destination" = "$DEFAULT_DESTINATION" ]; then
				# Add subfolder for TV series.
				destination=$(echo "$DEFAULT_TV_SERIES_DESTINATION${source_file_name%%$series_pattern*}" | sed 's/[^[:alnum:]_]*$//')
				destination="$destination/"
			fi
			destination_directory="$destination"

			# Check if $source_file_name starts with the series pattern.
			if echo "$source_file_name" | grep -q "^$series_pattern"; then
				# Keep everything before the TV series pattern
				destination="$source_file_name"
			else
				# Trim everything after TV series pattern.
				destination=$(echo "$source_file_name" | sed "s/$series_pattern.*//")
				destination="$destination$normalized_series"
			fi
		else
			# If no TV series pattern found, keep the original string and search movie pattern.
			current_year=$(date +%Y)

			# Find all occurrences of years that do not exceed the current year and are greater than or equal to 1900.
			valid_years=$(echo "$source_file_name" | grep -Eo "\b(19[0-9]{2}|20[0-$current_year]{1}[0-9]{1})\b" | awk -v current_year="$current_year" '{ if ($1 <= current_year) print $1 }')

			# Get the last valid year from the file name.
			last_year=$(echo "$valid_years" | tail -n 1)
			if [ -n "$last_year" ]; then
				# Truncate the file name after the last occurrence of the year.
				if echo "$source_file_name" | grep -q "(($last_year))"; then
					destination="${source_file_name%%(*}"
				elif echo "$source_file_name" | grep -q "($last_year)"; then
					destination="${source_file_name%%"($last_year)"*}"
				else
					destination="${source_file_name%"$last_year"*}"
				fi
				destination="$(echo "$destination" | tr ' ' '_')($last_year)"
			else
				# If do not found years then fallback to source file name.
				destination="$source_file_name"
			fi
		fi

		# Clean "."" and "_" in destination file name.
		destination=$(echo "$destination" | sed 's/\./ /g')	# Replace all . to space.
		destination=$(echo "$destination" | sed 's/_/ /g')	# Replace all _ to space.
		destination=$(echo "$destination" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//') # Remove both leading and trailing spaces.
		destination=$(echo "$destination" | sed 's#\(.*\) /#\1/#') # Replace last " /" to "/" for TV series directory creation.
		# Destination path + normalized file name + source extension.
		# Without video save file as mka file.
		if [ -n "$NOVIDEO_FLAG" ]; then
			# Save to source folder if no destination is set.
			if [ "$destination_directory" -ef "$DEFAULT_DESTINATION" ]; then
				destination="$source_directory/$source_file_name.mka"
			else destination="$destination_directory$destination.mka" #(no_video).$extension"
			fi
		else
			destination="$destination_directory$destination.$extension"
		fi

		if [ -z "$TEST_FLAG" ]; then
			echo
			echo "Source file: $source"
			echo "Destination file: $destination"
		fi

		# Check if source and destination are the same.
		if [ "$source" -ef "$destination" ] && [ -z "$TEST_FLAG" ]; then
			local error="Source and destination cannot be the same file (${source#"$source_directory"/})."
			errors="$errors$error\n"
			echo "$error"
			return 1
		fi

		# FFprobe command to extract video, audio and subtitles information.
		file_streams="$(ffprobe -v error -print_format json -show_entries stream=index,codec_type,codec_name:stream_tags=language,title "$source")"
			if [ $? -ne 0 ]; then
				local error="Error: Extracting stream information from (${1#"$source_directory"/})"
				errors="$errors$error\n"
				echo "$error"
				return 1
			fi
		file_streams=$(echo "$file_streams" | jq -r '[.streams[]|{index: .index, codec_name: .codec_name, codec_type: .codec_type, language: .tags.language, title: .tags.title}]')
		if [ -n "$file_streams" ] && [ -z "$TEST_FLAG" ]; then
			echo "$file_streams" | jq -r '[ "Id:", "Codec:", "Type:", "Language:", "Title:"], (.[] | {index: .index, codec_name: .codec_name, codec_type: .codec_type, language: .language, title: .title} | [.index, .codec_name, .codec_type, .language, .title]) | @csv' | awk -F ',' '{printf "%-5s %-20s %-11s %-11s %-0s\n", $1, $2, $3, $4, $5}' 
		fi

		# Select audio tracks based on preferred and fallback languages.
		selected_audio_tracks=""
		audio_language=""
		for language in $LANGUAGES; do
			audio_tracks="$(echo "$file_streams" | jq -r --arg lang "$language" '.[] | select(.codec_type == "audio" and .language == $lang) | .index')"
			if [ -n "$audio_tracks" ]; then
				selected_audio_tracks="$audio_tracks"
				audio_language=$language
				break
			fi
		done
		# Select default audio track language if no selected_audio_tracks.
		if [ -z "$selected_audio_tracks" ]; then 
			#TODO: Find better method to find default audio track than use all audio tracks.
			selected_audio_tracks="$(echo $file_streams | jq -r '.[] | select(.codec_type == "audio") | .index')"
		fi

		#add commentary audio
		#ffprobe -v error -show_entries stream=index:stream_tags=title -of default=noprint_wrappers=1 "$source" | grep -B 1 "Commentary"
		audio_commentary_index=""
		audio_commentary_index=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "audio" and .title != null)' | jq 'select(.title | contains("Commentary")).index')

		#echo "audio_commentary_index=$audio_commentary_index"
		# Sort and find unique indexes in audio_commentary_index that are not in audio_tracks
		if [ -n "$audio_commentary_index" ]; then
			selected_audio_tracks=$(echo "$selected_audio_tracks\n$audio_commentary_index" | sort -n | uniq)
		fi
		if [ -n "$selected_audio_tracks" ] && [ -z "$TEST_FLAG" ]; then
			echo "selected_audio_tracks:"
			echo "$selected_audio_tracks"
		fi

		# Run ffprobe to get information about the video streams.
		video_codecs=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "video") | .codec_name')

		# Check if any video codec is supported.
		video_codec_supported=""
		for video_codec in $video_codecs; do
			# Check if the codec is in the SUPPORTED_VIDEO_CODECS array.
			for supported_video_codec in $SUPPORTED_VIDEO_CODECS; do
				if [ "$supported_video_codec" = "$video_codec" ]; then
					video_codec_supported="true"
					break
				fi
			done
		done

		# Select subtitles.
		subtitle_language=""
		for language in $LANGUAGES; do
			subtitle_track=$(echo "$file_streams" | jq -r --arg lang "$language" '.[] | select(.codec_type == "subtitle" and .language == $lang) | .index')
			if [ -n "$subtitle_track" ]; then
				subtitle_language="$language"
				break
			fi

			# Do not include fall back languages.
			if [ "$audio_language" = "$language" ]; then
				break
			fi
		done

		#add commentary subtitles if differ than audio_language
		#ffprobe -v error -show_entries stream=index:stream_tags=title -of default=noprint_wrappers=1 "$source" | grep -B 1 "Commentary"
		subtitle_commentary_index=""
		subtitle_commentary_index=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "subtitle" and .title == "Commentary") | .index')
		# Sort and find unique indexes in audio_commentary_index that are not in audio_tracks
		if [ -n "$subtitle_commentary_index" ] && [ -z "$TEST_FLAG" ]; then
			subtitle_track=$(echo "$subtitle_track\n$subtitle_commentary_index" | sort -n | uniq)
			echo "subtitle_commentary_index:"
			echo "$subtitle_commentary_index"
		fi

		# If not found preferred audio or subtitles languages then take all subtitles.
		if [ -z "$audio_language" ]; then
			if [ -z "$subtitle_language" ]; then
				subtitle_track=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "subtitle") | .index')
			fi
		fi
		if [ -n "$subtitle_track" ] && [ -z "$TEST_FLAG" ]; then
			echo "selected subtitles:"
			echo "$subtitle_track"
			#echo "subtitle_language=$subtitle_language"
		fi

		# Build the FFmpeg command.
		# -xerror -fflags +fastseek -max_muxing_queue_size 999 -bitexact
		ffmpeg_command="ffmpeg -xerror -err_detect explode -flags -global_header -hide_banner -i \"$source\""

		# do not output video
		if [ -n "$NOVIDEO_FLAG" ]; then
			ffmpeg_command="$ffmpeg_command -vn"
			# add video and remove video file title if exist video track
		elif [ -n "$video_codecs" ]; then
			ffmpeg_command="$ffmpeg_command -map 0:v:0 -metadata title=\"\" -c:v copy -metadata:s:v title=\"\""
		fi

		# Map audio tracks.
		for audio_track in $selected_audio_tracks; do
			ffmpeg_command="$ffmpeg_command -map 0:$audio_track"
		done

		# Add audio tracks.
		audio_track_index=0
		# Count how much audio and subtitles tracks will be copied without conversation.
		not_changed_tracks=0
		for audio_track in $selected_audio_tracks; do
			audio_codec="$(echo "$file_streams" | jq -r --arg audio_track "$audio_track" '.[$audio_track|tonumber].codec_name')"

			# Check if a audio codec is supported.
			audio_codec_supported=""
			for supported_codec in $SUPPORTED_AUDIO_CODECS; do
				if [ "$audio_codec" = "$supported_codec" ]; then
					audio_codec_supported="true"
					break
				fi
			done

			# Decide convert or copy audio track.
			if [ -n "$video_codec_supported" ] || [ -z "$video_codecs" ] || [ -n "$NOVIDEO_FLAG" ]; then
				if [ -n "$audio_codec_supported" ]; then
					ffmpeg_command="$ffmpeg_command -c:a:$audio_track_index copy"
					not_changed_tracks=$(( not_changed_tracks + 1 ))
				else
					ffmpeg_command="$ffmpeg_command -c:a:$audio_track_index $CONVERT_AUDIO_CODEC"
				fi
			else
				ffmpeg_command="$ffmpeg_command -c:a:$audio_track_index copy"
				not_changed_tracks=$(( not_changed_tracks + 1 ))
			fi
			audio_track_index=$(( audio_track_index + 1 ))
		done

		# Add subtitles to FFmpeg command.
		if [ -n "$subtitle_track" ]; then
			for track in $subtitle_track; do
				ffmpeg_command="$ffmpeg_command -map 0:$track"
				not_changed_tracks=$(( not_changed_tracks + 1 ))
			done
			# Do not convert subtitles.
			ffmpeg_command="$ffmpeg_command -c:s copy"
		fi

		ffmpeg_command="$ffmpeg_command \"$destination\""

		# Count source audio and subtitles tracks.
		audio_and_subtitle_count=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "audio" or .codec_type == "subtitle") | .index' | grep -c "")

		# Check need of conversation audio or strip some tracks.
		if [ "$not_changed_tracks" -eq "$audio_and_subtitle_count" ]; then

			# Check if the choice is already set
			if [ -z "$copy_file_choice" ] && [ -z "$TEST_FLAG" ] && [ -z "$NOVIDEO_FLAG" ]; then
				# Prompt the user for input if choice is not set.
				read -p "Do not need convert file. Do you want to copy it to ($destination)? Choice is permanent for all files! (y/n).: " choice_copy_file
				copy_file_choice="$choice_copy_file"
			fi

			# Always copy audio if output only audio
			if [ -n "$NOVIDEO_FLAG" ]; then 
				copy_file_choice="y"
			fi

			# Use the stored choice.
			if [ "$copy_file_choice" = "y" ]; then
						# Copy the file with ffmpeg but do not output video
						if [ -n "$NOVIDEO_FLAG" ]; then
							ffmpeg_command="ffmpeg -xerror -err_detect explode -flags -global_header -hide_banner -i \"$source\" -vn -c copy \"$destination\""
						else
							# Copy the file with ffmpeg and show progress.
							ffmpeg_command="ffmpeg -xerror -err_detect explode -flags -global_header -hide_banner -i \"$source\" -c copy -metadata:s:v title=\"\" \"$destination\""
						fi
			else
				error="Skipping (${1#"$source_directory"/}) because do not need to convert this file."
				errors="$errors$error\n"
				echo "$error"
				return 1
			fi
		fi

		# Create not existing destination directory.
		directory=$(dirname "$destination")
		if [ ! -d "$directory" ] && [ -z "$TEST_FLAG" ]; then
				# Check if the choice is already set
				if [ -z "$create_directory_choice" ]; then
					# Prompt the user for input if choice is not set.
					read -p "Destination directory ($directory) does not exist. Do you want to create it?. Choice is permanent! (y/n): " choice_create_directory
					create_directory_choice="$choice_create_directory"
				fi

				# Use the stored choice.
				if [ "$create_directory_choice" = "y" ]; then
					mkdir -p "$directory"
					echo "Created destination ($directory) directory."
				else
					error="Error: FFmpeg cannot create file in non-existing directory. Skipping (${source#"$source_directory"/}) file."
					errors="$errors$error\n"
					echo "$error"
					return 1
				fi
		fi

		# Record the FFmpeg start time.
		start_time=$(date +%s)

		echo "$ffmpeg_command"

		if [ -z "$TEST_FLAG" ]; then
			# Run FFmpeg command.
			eval "$ffmpeg_command"

			# Check FFmpeg errors.
			if [ $? -ne 0 ]; then
				# Record the FFmpeg end time.
				end_time=$(date +%s)
				execution_time=$((end_time - start_time))
				error="Error: ($ffmpeg_command) \n"
				errors="$errors$error"
				echo "$error"
				return 1
			fi
		else
			end_time=$(date +%s)
			execution_time=$((end_time - start_time))
			return 1
		fi

		# Record the FFmpeg end time.
		end_time=$(date +%s)

		# Calculate the difference in seconds.
		execution_time=$((end_time - start_time))
		# Format the execution time using date command.
		formatted_time=$(date -u -d @"$execution_time" +"%T")
		# Output time in format hours:minutes:seconds how long took function and how long took whole script to finish.

		# Compare source and destination files after conversation.
		destination_size=0
		source_size=$(stat "$source" | grep "Size:" | awk '{print $2}')
		if [ -f "$destination" ]; then
			destination_size=$(stat "$destination" | grep "Size:" | awk '{print $2}')
		fi

		# Calculate the difference in sizes.
		size_difference=$((source_size - destination_size))

		# Check if the destination file is bigger than the source file.
		if [ "$destination_size" -gt "$source_size" ]; then
			error="Error: Destination file (${destination#"$input_destination"}) is bigger than source file (${source#"$source_directory"/})."
			errors="$errors$error\n"
			return 1
		fi

		# Check if the destination file is less than 10% of the source file size.
		ten_percent=$((source_size / 10))
		if [ "$destination_size" -lt "$ten_percent" ] || [ "$destination_size" -eq 0 ] && [ -z "$NOVIDEO_FLAG" ]; then
			error="Error: Destination file (${destination#"$input_destination"}) is less than 10% of the source file. Deleting it."
			errors="$errors$error\n"
			echo "$error"

			# delete destination file.
			if [ -f "$destination" ]; then
				rm "$destination"
			fi
			return 1
		fi

		# Make destination file creation date same as source.
		if [ -f "$destination" ]; then
			touch -r "$source" "$destination"
		else 
			error="Error: Destination file (${destination#"$input_destination"}) does not exist."
			errors="$errors$error\n"
			echo "$error"
			return 1
		fi

		if [ -z "$messages_without_mistakes" ]; then
			messages_without_mistakes="Successful conversations:\n"
		fi

		# Register all successful fmmpeg commands.
		messages_without_mistakes="$messages_without_mistakes$ffmpeg_command\n"
		# Output saved disk size.
		saved_size="Saved: $(human_readable_size $size_difference) and it took $formatted_time to do so."
		messages_without_mistakes="$messages_without_mistakes$saved_size\n\n"
		echo "$saved_size"
		# Update the total difference.
		total_diff=$((total_diff + size_difference))
	fi
}

# Function to check a file for errors.
check_file(){
	if is_valid_file "$1"; then
		source_file_name="${1#"$source_directory"/}"
		if [ -z "$TEST_FLAG" ]; then
			echo "Checking ($source_file_name) for errors"
		fi

		# Record the FFmpeg start time.
		start_time=$(date +%s)

		#eval ffmpeg -err_detect explode -v error -hide_banner -i \"$1\" -c copy -f null - 2>&1 >/dev/null
		# Run ffmpeg and capture its output and exit status
		#be video
		#ffmpeg_output=$(ffmpeg -v error -i "$1" -vn -f null - 2>&1)
		#ffmpeg_output=$(ffmpeg -v error -xerror -err_detect explode -i "$1" -f null - 2>&1)
		#ffmpeg -xerror -err_detect explode -hide_banner -i "$1" -f null -
		#ffmpeg -hwaccels -hide_banner #parodo gpu akseleracijas
		#ffmpeg -hwaccel vaapi -vaapi_device /dev/dri/renderD128 -xerror -err_detect explode -hide_banner -i "$1" -f null - #dirba 10x lėčiau
		# ffmpeg_output nerodo statuso bet pagauna daugiau klaidų
		#echo "ffmpeg -benchmark -hwaccel vdpau -xerror -err_detect explode -v error -i \"$1\" -f null - 2>&1"
		#ffmpeg_output=$(ffmpeg -benchmark -hwaccel vdpau -xerror -err_detect explode -v error -i "$1" -f null - 2>&1)

		#Rodo ffmpeg statusą bet nepagauna visų klaidų
		ffmpeg_command="ffmpeg -benchmark -hwaccel vdpau -xerror -err_detect explode -hide_banner -i \"$1\" -f null -"
		#ffmpeg_command="ffmpeg -benchmark -hwaccel cuda -xerror -err_detect explode -hide_banner -i \"$1\" -f null -"
		echo "$ffmpeg_command"

		if [ -z "$TEST_FLAG" ]; then
			# Run FFmpeg command.
			eval "$ffmpeg_command"

			# Check FFmpeg errors.
			if [ $? -ne 0 ]; then
				# Record the FFmpeg end time.
				end_time=$(date +%s)
				execution_time=$((end_time - start_time))
				formatted_time=$(date -u -d @"$execution_time" +"%T")
				error="Error: in ($source_file_name). Check took $formatted_time to do so."
				errors="$errors$source_file_name\n"
				echo "$error"
				return 1
			else
				end_time=$(date +%s)
				execution_time=$((end_time - start_time))
				formatted_time=$(date -u -d @"$execution_time" +"%T")
				if [ -z "$messages_without_mistakes" ]; then
					messages_without_mistakes="Files without errors:\n"
				fi
				echo "File is OK: ($source_file_name). Check took $formatted_time to do so."
				messages_without_mistakes="$messages_without_mistakes$source_file_name\n"
				return 0
			fi
		else
			# Dry run. Do nothing.
			end_time=$(date +%s)
			execution_time=$((end_time - start_time))
			return 1
		fi

		end_time=$(date +%s)
		execution_time=$((end_time - start_time))
		# Format the execution time using date command.
		formatted_time=$(date -u -d @"$execution_time" +"%T")
		# Output time in format hours:minutes:seconds how long took function and how long took whole script to finish.

		
		# Check if ffmpeg produced any output (indicating an error).
		if [ -n "$ffmpeg_output" ]; then
		# Check if ffmpeg exit code not 0 (indicating an error).
		#if [ $? -ne 0 ]; then
			#echo "File have errors: $ffmpeg_output"
			echo "File have errors: ($source_file_name). Check took $formatted_time to do so."
			errors="$errors$source_file_name\n"
		else
			if [ -z "$messages_without_mistakes" ]; then
				messages_without_mistakes="Files without errors:\n"
			fi
			echo "File is OK: ($source_file_name). Check took $formatted_time to do so."
			messages_without_mistakes="$messages_without_mistakes$source_file_name\n"
		fi
	fi
}

# Function to process files in a directory recursively.
process_directory() {
	source="$1"

	# Loop through files and subfolders in the folder.
	for entry in "$source"/*; do
		if [ -d "$entry" ]; then
		# Recursively process subfolders.
		process_directory "$entry"

		elif [ -f "$entry" ]; then

			# Set same subfolder for destination as source.
			directory=$(dirname "$entry")
			subfolder="${directory#"$source_directory"/}"
			if [ "$directory" = "$subfolder" ]; then
				subfolder=""
			fi

			# Determine the operation based on --check parameter.
			if [ -n "$CHECK_FLAG" ]; then
				# Check files
				check_file "$entry"
			else
				if [ -n "$subfolder" ];then
					destination="$input_destination$subfolder/"
				else
					destination="$input_destination"
				fi
				# Convert files
				convert_file "$entry" "$destination"
			fi
		fi
		subfolder=""
	done
}

# Program start:

checkpackage "ffprobe"
checkpackage "ffmpeg"

# Record script start time.
script_start_time=$(date +%s)

# Check files for errors
CHECK_FLAG=""
# Output only audio
NOVIDEO_FLAG=""
# Dry run conversation
TEST_FLAG=""

source="$DEFAULT_SOURCE"
destination="$DEFAULT_DESTINATION"
while [ "$1" ]; do
	case $1 in
		-h|--help)
			echo "  If no parameters are provided, default source and destination are used."
			echo "  Default source is $DEFAULT_SOURCE"
			echo "  Default destination is $DEFAULT_DESTINATION"
			echo "  Source can be file or directory."
			echo "  Destination can be only directory."
			echo "  Supported files extensions $EXTENSIONS"
			echo "  If one parameter is provided, it is considered as the source."
			echo "  If two parameters are provided the first is source, second is destination."
			echo "  -c or --check arguments checks file for errors."
			echo "  -v or --novideo arguments excludes video."
			echo "  -t or --test arguments only print ffmepg commands (dry run)."
			echo "Example:"
			echo "  $(basename "$0")			# Use default source and destination."
			echo "  $(basename "$0") source		# Use source as specified."
			echo "  $(basename "$0") -c source		# Check specified source for errors."
			echo "  $(basename "$0") -v source		# Do not add video to output file."
			echo "  $(basename "$0") -t source		# Dry run without actual conversation."
			echo "  $(basename "$0") source destination	# Use specified source and destination."
			exit 0
			;;
		-c|--check)
			CHECK_FLAG=true
			shift
			;;
		-v|--novideo)
			NOVIDEO_FLAG=true
			shift
			;;
		-t|--test)
			TEST_FLAG=true
			shift
			;;
		*)
			# One parameter is provided, consider it as source.
			if [ "$source" = "$DEFAULT_SOURCE" ]; then
				source=$1
			# If two parameters are provided the first consider as source, second as destination.
			elif [ "$destination" = "$DEFAULT_DESTINATION" ]; then
				destination=$1
			else
				echo "Error: in given arguments."
				exec "$0" -h
				exit 1
			fi
			shift
			;;
	esac
done

# Get the last character of the destination.
last_char=$(printf "%s" "$destination" | tail -c 1)

# Check if the last character is "/" in destination. If not, add "/".
if [ "$last_char" != "/" ]; then
	destination="$destination/"
fi

# Check more file extensions than user ask.
if [ -n "$CHECK_FLAG" ]; then
#	echo "Run ffmpeg -formats and extract the formats. Please wait..."
#	# Run ffmpeg -formats and extract the formats
#	EXTENSIONS=$(ffmpeg -demuxers -hide_banner | tail -n +5 | cut -d' ' -f4 | xargs -i{} ffmpeg -hide_banner -h demuxer={} | grep 'Common extensions' | cut -d' ' -f7 | tr ',' $'\n' | tr -d '.'))
#	# Because very slow extract formats it is faster use baked variable.
	EXTENSIONS=".3g2 .3gp .aa3 .aac .ac3 .avi .dss .dts .eac3 .flac .flv .hevc .m2a .m4a .m4v .mka .mks .mkv .mov .mp2 .mp3 .mp4 .ogg .vc1"
fi

# If source is file then determine the operation based on --check parameter.
if [ -f "$source" ]; then
	source_directory=$(dirname "$source")
	# Determine the operation based on check value.
	if [ -n "$CHECK_FLAG" ]; then
		# Check files
		check_file "$source"
	else
		# Convert files
		convert_file "$source" "$destination"
	fi
return 0 # Exit without messages output
# If source is directory then remember user file paths. and remove "/" from source.
elif [ -d "$source" ]; then

	# Check if the last character of $source is '/'
	last_char=$(printf "%s" "$source" | tail -c 1)
	if [ "$last_char" = "/" ]; then
		# Remove the last character '/'.
		source="${source%?}"
	fi

	# Directories inputted by user or default.
	source_directory="$source"
	input_destination="$destination"

	process_directory "$source"
else
	echo "Source ($source) does not exist or is not a media file. Use existing files with these $EXTENSIONS extensions or directory."
	exit 1
fi

# Messages output.
if [ -n "$messages_without_mistakes" ] || [ -n "$errors" ]; then
	echo
	echo "Procesed files in directory $source_directory/"
fi

# Output successful ffmpeg commands.
if [ -n "$messages_without_mistakes" ]; then
	echo "$messages_without_mistakes"
fi

# Output files with errors.
if [ -n "$errors" ] && [ -z "$TEST_FLAG" ] ; then
	echo
	echo "Files with errors is:\n$errors"
fi

# Record the end time.
script_end_time=$(date +%s)

# Calculate the difference in seconds.
script_execution_time=$((script_end_time - script_start_time))

# Format the execution time using date command.
formatted_time=$(date -u -d @"$script_execution_time" +"%T")

if [ -n "$TEST_FLAG" ]; then
	echo "Dry run took $formatted_time."
elif [ -n "$CHECK_FLAG" ]; then
	echo "All files check complete in $formatted_time"
else
	echo "Total saved: $(human_readable_size $total_diff) and it took $formatted_time to do so."
fi