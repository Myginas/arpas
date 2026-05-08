#!/bin/sh
# Tab size: 4
#################################################################################
# Description:	Script for LibreELEC to remove unnecessary audio and subtitles	#
#				from media files. Convert not supported audio codecs.			#
#				Rename files. Move metadata files. Clean nfo files.				#
# Date: [2026-05-05]															#
# Version: [1.8]																#
# Add: Source and destination file size output. Before overwriting output		#
#	destination file information. Prefer professional subtitles. Config file.	#
#	Import audio and subtitle track title from existing file. 					#
#	Prefer select subrip over hdmv_pgs_subtitles.								#
# Fix: Professional audio selection for cyrillic titles. Audio selection logic.	#
#	selected audio tracks count. Commentary audio fallback.	ffmpeg could not	#
#	find codec parameter warning.												#
# Remove: Do not include selected language and fall back languages.				#
#################################################################################

# Loop through all command-line arguments to check for "-d" or "--debug"
DEBUG=false
for script_argument in "$@"; do
	if [ "$script_argument" = "-d" ] || [ "$script_argument" = "--debug" ]; then
		DEBUG=true
		break
	fi
done
unset script_argument

# Enable debugging.
if $DEBUG; then
	unset DEBUG
	if command -v shellcheck > /dev/null 2>&1; then
		shellcheck "$0"
	fi
	PS4='${LINENO}:'
	set -x
fi

# Record script start time.
script_start_time=$(date +%s)

# Global variables declaration.
total_size_difference=0 # Global variable to keep track of total file size difference.
errors="" # Global variable to keep track files with conversation errors.
messages_without_mistakes="" # Global variable to keep track files without conversation errors.
size_difference=0 # Difference in bytes between source and destination files.
ffmpeg_run_time=0 # Time to complete FFmpeg command in seconds.
processed_files_count=0 # Count processed files.

# Function to handle empty variables and set defaults.
set_default_variables() {
	var_type="$1"
	var_name="$2"
	default_value="$3"
	case "$var_type" in
		"constant string")
			if eval "[ -z \"\${$var_name}\" ]"; then
				if $print_config_error; then
					printf '%s is not set, setting to default value: %s\n' "$var_name" "$default_value"
				fi
				eval readonly "$var_name='$default_value'"
			fi
			;;
		"variable string")
			if eval "[ -z \"\${$var_name}\" ]"; then
				if $print_config_error; then
					printf '%s is not set, setting to default value: %s\n' "$var_name" "$default_value"
				fi
				eval "$var_name='$default_value'"
			fi
			;;
		integer)
			if ! eval "printf '%s\n' \"\$$var_name\"" | grep -qE '^[0-9]+$'; then
					printf '%s is not an number, setting to default value: %s\n' "$var_name" "$default_value"
					eval "$var_name='$default_value'"
			fi
			;;
		boolean)
			if ! eval "printf '%s\n' \"\$$var_name\"" | grep -qE '^(true|false)$'; then
				printf '%s is not a boolean (true/false), setting to default value: %s\n' "$var_name" "$default_value"
				eval "$var_name='$default_value'"
			fi
			;;
		"numerical list")
			if eval "[ -n \"\${$var_name}\" ]"; then
				if ! eval "printf '%s\n' \"\$$var_name\"" | grep -qE '^[0-9]+([, ]+[0-9]+)*$'; then
					printf '%s does not contain a valid numerical list (numbers separated by commas or spaces), seting it to empty.\n' "$var_name"
					eval "$var_name=\"\""
				fi
			fi
			;;
	esac
}

# Function to store and output to screen error messages.
error() {
	errors="$errors$1\n"
	# Print when second parameter not given.
	if [ -z "$2" ]; then
		printf '\e[38;5;196m⚠️ %b\e[0m\n' "$1"
	fi
}

# Function to ensure last character of string.
confirm_last_character() {
	last_character=$(printf '%s' "$1" | tail -c 1)
	if [ "$last_character" != "$2" ]; then
		echo "$1$2"
	else
		echo "$1"
	fi
	unset last_character
}

# Function to convert bytes to human readable form.
human_readable_size(){
	SIZE="$1" # input size in bytes
	UNITS="B KB MB GB TB PB" # list of unit prefixes.

	# Iterate through the units, starting from the smallest and working our way up.
	for UNIT in $UNITS; do
		test "${SIZE%.*}" -lt 1000 && break;

		# Divide the size by 1000 to get a new value for the next unit.
		SIZE=$(awk "BEGIN {printf \"%.2f\",${SIZE}/1000}")
	done

	# if the unit is still "B" at this point, it means we've already converted the size to bytes.
	# In that case, just print the size with a single space before the unit.
	if [ "$UNIT" = "B" ]; then
		printf '%4.0f %s\n' "$SIZE" "$UNIT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
	else
		printf '%7.02f %s\n' "$SIZE" "$UNIT "| sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
	fi
	unset SIZE UNIT UNITS
}

# Main function to rename file, remove video, audio, subtitles and convert unsupported audio tracks.
convert_file(){
	source="$1" # Source /path/folder/file.extension 

	destination="$2" # Destination /path/ in future will be /path/folder/file.extension
	destination_directory="$2" # Destination /path/

	# Extract the parent directory of the source path.
	source_directory=$(dirname "$source") # /path/folder
	source_folder="${source_directory##*/}" # folder
	source_directory="$source_directory/" # /path/folder/

	# FFprobe command to extract video, audio and subtitles information.
	if ! file_streams="$(ffprobe -v error -print_format json -show_entries stream=index,codec_type,codec_name:stream_tags=language,title "$source")";then
		error "Extracting stream information from ${1#"$source_directory"}." "do not print"
		return 1
	fi

	# Output source file information.
	source_size=$(stat "$source" | grep "Size:" | awk '{print $2}')
	echo
	echo "Source file: $source $(human_readable_size "$source_size")"

	file_streams=$(echo "$file_streams" | jq -r '[.streams[]|{index: .index, codec_name: .codec_name, codec_type: .codec_type, language: .tags.language, title: .tags.title}]')
	json_query_command='(["ID:","CODEC:","TYPE:","LANGUAGE:","TITLE:"]), (.[] | [.index, .codec_name, .codec_type, .language, .title]) | @tsv'
	echo "$file_streams" | jq -r "$json_query_command" | awk -F '\t' '{printf "%-3s %-17s %-9s %-9s %-0s\n", $1, $2, $3, $4, $5}'
	unset json_query_command

	# Get video streams codecs.
	video_codecs=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "video" and .codec_name != "mjpeg" and .codec_name != "jpeg" and .codec_name != "png") | .codec_name')

	# Check if any video codec is supported.
	video_codec_supported=false
	for video_codec in $video_codecs; do
		# Check if the codec is in the SUPPORTED_VIDEO_CODECS array.
		for supported_video_codec in $SUPPORTED_VIDEO_CODECS; do
			if [ "$supported_video_codec" = "$video_codec" ]; then
				video_codec_supported=true
				break 2  # Breaks out of both the inner and outer loops.
			fi
		done
	done
	unset video_codec supported_video_codec

	# Make destination path from destination path and source file name.
	source_extension=$(echo "$source" | awk -F. '{print $NF}')
	if $video_codec_supported && [ "$source_extension" != "mka" ]; then
		destination_extension="mkv"
	else
		destination_extension="$source_extension"
	fi

	source_file_name=$(basename "$source")
	source_file_name="${source_file_name%.*}" # File name without extension.

	destination_folder="${destination_directory%/*}" # /path/folder/file
	destination_folder="${destination_folder##*/}"	 # folder

	# Clean symbols in source_file_name.
	renamed_file_name=$source_file_name
	renamed_file_name=$(echo "$renamed_file_name" | sed 's/\.\./tas_hkas/g') # Replace .. to tas_hkas
	renamed_file_name=$(echo "$renamed_file_name" | sed 's/\./ /g')	# Replace all . to space.
	renamed_file_name=$(echo "$renamed_file_name" | sed 's/tas_hkas/./g') # Replace tas_hkas to .
	renamed_file_name=$(echo "$renamed_file_name" | sed 's/_/ /g')	# Replace all _ to space.
	renamed_file_name=$(echo "$renamed_file_name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//') # Remove both leading and trailing spaces.
	renamed_file_name=$(echo "$renamed_file_name" | sed 's/ \+/ /g' ) # Substitute multiple spaces with a single space.
	renamed_file_name=$(echo "$renamed_file_name" | sed 's#\(.*\) /#\1/#') # Replace last " /" to "/" for TV series directory creation.

	# Regular expression to match various TV series patterns.
	series_pattern=$(echo "$renamed_file_name" | grep -Eo "([Ss])([0-9]+)[._ -]?([Ee])([0-9]+)")

	if [ -n "$series_pattern" ]; then
		for pattern in $series_pattern;do
			# If TV series pattern found, normalize it to the "S01E01" format.
			season=$(echo "$pattern" | sed -E 's/[^0-9]*([0-9]+)[^0-9]+([0-9]+)/\1/')
			episode=$(echo "$pattern" | sed -E 's/[^0-9]*([0-9]+)[^0-9]+([0-9]+)/\2/')
			# Remove leading zeros from season and episode variables.
			season=$(echo "$season" | sed 's/^0*//')
			episode=$(echo "$episode" | sed 's/^0*//')
			normalized_series="$(printf '%s' "$normalized_series")S$(printf '%02d' "$season")E$(printf '%02d' "$episode")"
		done
		unset pattern season episode

		# Add subfolder for TV series if destination folder not same as source folder.
		if [ "$destination_folder" != "$source_folder" ]; then
			destination_directory="$destination_directory$source_folder/"
		fi

		# Check if $renamed_file_name starts with the series pattern.
		if echo "$renamed_file_name" | grep -q "^$series_pattern"; then
			# Replace series patern to normalized series of renamed file.
			destination=$(echo "$renamed_file_name" | sed "s/$series_pattern/$normalized_series/g")
		else
			# Trim everything after TV series pattern.
			destination=$(echo "$renamed_file_name" | sed "s/$series_pattern.*//")
			destination="$destination$normalized_series"
		fi
		unset renamed_file_name normalized_series series_pattern
	else
		# If no TV series pattern found, keep the original string and search movie pattern.
		# If destination starts with DEFAULT_TV_SHOWS_DESTINATION change it to DEFAULT_MOVIE_DESTINATION.
		if echo "$destination_directory" | grep -q "^$DEFAULT_TV_SHOWS_DESTINATION"; then
			destination_directory=$(echo "$destination_directory" | sed "s|$DEFAULT_TV_SHOWS_DESTINATION|$DEFAULT_MOVIE_DESTINATION|g")
		fi

		# Assumption that script not run in year change time.
		if [ -z "$current_year" ];then
			current_year=$(date +%Y)
		fi
		# Extract all four-digit numbers from the renamed_file_name and filter out the between 1902 and current_year.
		for year in $(echo "$renamed_file_name" | grep -oE '[0-9]{4}'); do
			# First movie was released 1902.
			if [ "$year" -ge 1902 ] && [ "$year" -le "$current_year" ]; then
				valid_year=$year
			fi
		done
		unset year

		 # Check if the variable 'valid_year' is not empty.
		if [ -n "$valid_year" ]; then
			# Truncate the file name after the last occurrence of the year.
			# If the filename contains the year surrounded by double parentheses (e.g., "file((2023))").
			if echo "$renamed_file_name" | grep -q "(($valid_year))"; then
				destination="${renamed_file_name%%(*}"
			# If the filename contains the year surrounded by parentheses (e.g., "file(2023)").
			elif echo "$renamed_file_name" | grep -q "($valid_year)"; then
				destination="${renamed_file_name%%"($valid_year)"*}"
			else # If the filename contains the year without surrounding parentheses (e.g., "file2023").
				destination="${renamed_file_name%"$valid_year"*}"
			fi
			unset renamed_file_name

			# Check if the last character is " " in destination. If not, add " ".
			destination=$(confirm_last_character "$destination" " ")
			# Output in "destination (2023)" format.
			destination="$destination($valid_year)"
			unset valid_year
		else
			# If do not found years then fallback to source file name.
			destination="$source_file_name"
		fi

		# Rename parent movie folder if it same as file name.
		if [ -f "${source%.*}.nfo" ] || [ -f "$source_directory""movie.nfo" ] || [ "$source_folder" = "$source_file_name" ];then
			# Add folder if destination not same as source file name and destination.
			if [ "$source_file_name" != "$destination_folder" ]; then
				if [ "$destination_folder" != "$destination" ]; then
					destination_directory="$destination_directory$destination/"
				fi
			else
				# Replace destination_folder with destination.
				destination_directory=$(echo "$destination_directory" | sed "s/$source_folder/$destination/")
			fi
		fi
	fi

	# Rename destination_folder if it is same as source file name.
	if [ "$source_file_name" = "$destination_folder" ]; then
		destination_directory=$(echo "$destination_directory" | sed "s/$destination_folder/$destination/")
		destination_folder="$destination"
	fi

	# Audio file save as .mka in source directory.
	if $NO_VIDEO_FLAG; then
		destination_extension="mka"
		if echo "$destination_directory" | grep -q "^$DEFAULT_TV_SHOWS_DESTINATION"; then
			destination="${source%.*}.$destination_extension"
		elif echo "$destination_directory" | grep -q "^$DEFAULT_MOVIE_DESTINATION"; then
			destination="${source%.*}.$destination_extension"
		fi
	fi

	# Destination path + normalized file name + source extension.
	destination="$destination_directory$destination.$destination_extension"

	# Select audio tracks based on preferred and fallback languages.
	for language in $LANGUAGES; do
		audio_tracks="$(echo "$file_streams" | jq -r --arg lang "$language" '.[] | select(.codec_type == "audio" and .language == $lang) | .index')"
		if [ -n "$audio_tracks" ]; then
			selected_audio_tracks="$audio_tracks"

			# Prefer select professional audio tracks.
			selected_audio_tracks_count=$(echo "$selected_audio_tracks" | grep -c '[^[:space:]]')
			if [ "$selected_audio_tracks_count" -gt 1 ] && [ -z "$audio_track_user_choice" ]; then
				# "i" makes the regex case-insensitive. Matches "prof", "Prof", "PROF", etc.
				profesional_audio_tracks="$(echo "$file_streams" | jq -r --arg lang "$language" '.[] | select(.codec_type == "audio" and .title != null and .language == $lang) | select(.title | test("prof|Проф"; "i")) | .index')"
				if [ -n "$profesional_audio_tracks" ]; then
					selected_audio_tracks="$profesional_audio_tracks"
				fi
				unset profesional_audio_tracks
			fi
			audio_language=$language
			break
		fi
	done
	unset language

	# If more than one selected audio track then ask user select tracks to keep.
	if [ "$selected_audio_tracks_count" -gt 1 ]; then
		# Check if -a parameter is given to script.
		if [ -z "$audio_track_user_choice" ]; then
			# Construct the jq command dynamically.
			for selected_audio_track in $selected_audio_tracks; do
			# Append audio index element to jq command.
				if [ -z "$json_query_command" ]; then
					json_query_command="$selected_audio_track"
				else
					json_query_command="$json_query_command,$selected_audio_track"
				fi
			done
			unset selected_audio_track

			echo
			echo "⚠️ Found $selected_audio_tracks_count audio tracks of $audio_language language"
			json_query_command='(["ID:","LANGUAGE:","TITLE:"]), (.['"$json_query_command"'] | [.index, .language, .title]) | @tsv'
			echo "$file_streams" | jq -r "$json_query_command" | awk -F '\t' '{printf "%-3s %-9s %-0s\n", $1, $2, $3}'
			unset selected_audio_tracks_count json_query_command

			# Read user input.
			echo "Write audio track ID that you want to keep, multiple ID's can be separated by spaces."
			printf "To select all tracks press ENTER:"
			read -r audio_track_user_choice
			#tr -d '[:punct:]'` to remove any punctuation from the input, ensuring that it doesn't contain special characters.
			audio_track_user_choice=$(echo "$audio_track_user_choice" | tr -d '[:punct:]')
		fi

		# Split the user input in words and check each one.
		for user_audio_track in $audio_track_user_choice; do
			if echo "$user_audio_track" | grep -q '^[0-9]'; then
				for selected_audio_track in $selected_audio_tracks; do
					if [ "$user_audio_track" -eq "$selected_audio_track" ]; then
						if [ -n "$user_selected_audio_tracks" ];then
							user_selected_audio_tracks="$user_selected_audio_tracks $user_audio_track"
						else
							user_selected_audio_tracks="$user_audio_track"
						fi
						break
					fi
				done
			fi
		done
		unset user_audio_track selected_audio_track

		# Change selected audio track to user selected audio tracks.
		if [ -n "$user_selected_audio_tracks" ]; then
			selected_audio_tracks="$user_selected_audio_tracks"
			unset user_selected_audio_tracks
		fi

		# Reset audio track choice if not set as script argument.
		if ! $AUDIO_FLAG; then
			unset audio_track_user_choice
		fi
	fi

	# Count selected audio track before adding commentary audio.
	if [ -n "$selected_audio_tracks" ]; then
		selected_audio_tracks_count=$(echo "$selected_audio_tracks" | grep -c '[^[:space:]]')
	else
		selected_audio_tracks_count=0
	fi

	# Output existing destination file information.
	if [ -f  "$destination" ]; then
		if destination_file_streams="$(ffprobe -v error -print_format json -show_entries stream=index,codec_type,codec_name:stream_tags=language,title "$destination")";then
			destination_file_streams=$(echo "$destination_file_streams" | jq -r '[.streams[]|{index: .index, codec_name: .codec_name, codec_type: .codec_type, language: .tags.language, title: .tags.title}]')
			echo
			destination_size=$(stat "$destination" | grep "Size:" | awk '{print $2}')
			echo "Existing destination file: $destination $(human_readable_size "$destination_size")"
			json_query_command='[ "ID:", "CODEC:", "TYPE:", "LANGUAGE:", "TITLE:"], (.['"$json_query_command] | {index: .index, codec_name: .codec_name, codec_type: .codec_type, language: .language, title: .title} | [.index, .codec_name, .codec_type, .language, .title]) | @tsv"
			echo "$destination_file_streams" | eval "jq -r '$json_query_command'" | awk -F '\t' '{printf "%-3s %-17s %-9s %-9s %-0s\n", $1, $2, $3, $4, $5}'
			unset destination_size json_query_command
		fi
	fi

	# Transfer audio title from egzisting destination file. Only when selected and destination audio tracks is only one, and source does not have audio title, and destination has.
	if [ -f "$destination" ] && [ -n "$destination_file_streams" ] && [ "$selected_audio_tracks_count" -eq 1 ]; then
		source_audio_title="$(echo "$file_streams" | jq -r --arg lang "$audio_language" '.[] | select(.codec_type == "audio" and .language == $lang and .title != null) | .title')"
		destination_audio_titles="$(echo "$destination_file_streams" | jq -r --arg lang "$audio_language" '.[] | select(.codec_type == "audio" and .language == $lang and .title != null) | .title')"
		destination_audio_titles_count=$(echo "$destination_audio_titles" | grep -c '[^[:space:]]')
		if [ -z "$source_audio_title" ] && [ "$destination_audio_titles_count" -eq 1 ]; then
			printf 'Source audio track %s, lang:%s does not have title. Overwrite it from destination file with "%s"? [y/N] ' "$selected_audio_tracks" "$audio_language" "$destination_audio_titles"
			read -r transfer_audio_title_user_choice
			case "$transfer_audio_title_user_choice" in
				y|Y)
					source_audio_index="$selected_audio_tracks"
					destination_audio_title="$destination_audio_titles"
					# Transfer audio title to file_streams.
					file_streams=$(echo "$file_streams" | jq --arg index "$source_audio_index" --arg title "$destination_audio_title" '.[] |= if .index == ($index | tonumber) then .title = $title else . end')
					;;
				*)
					unset source_audio_index destination_audio_title
					;;
			esac
			unset transfer_audio_title_user_choice
		fi
	fi
	unset source_audio_title destination_audio_titles destination_audio_titles_count

	# Select all audio tracks if not found preferred and fallback tracks.
	if [ -z "$selected_audio_tracks" ]; then
		# Select all audio tracks if not found preferred languages.
		selected_audio_tracks="$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "audio") | .index')"
	else
		# Add commentary audio.
		commentary_audio="$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "audio" and .title != null) | select(.title | test("Commentary"; "i"))')"
		if [ -n "$commentary_audio" ]; then
			# Select commentary audio by languages.
			for language in $LANGUAGES; do
				# # Do not include selected language and fall back languages.
				# if [ "$audio_language" = "$language" ]; then
				# 	break
				# fi

				commentary_audio_track=$(echo "$commentary_audio" | jq -r --arg lang "$language" '. | select(.language == $lang) | .index')
				if [ -n "$commentary_audio_track" ]; then
					if [ -n "$selected_audio_tracks" ];then
						selected_audio_tracks="$selected_audio_tracks $commentary_audio_track"
					else
						selected_audio_tracks="$commentary_audio_track"
					fi
					break
				fi
			done
			unset commentary_audio commentary_audio_track
		fi
	fi

	# Select subtitles.
	subtitle_tracks_count=0
	for language in $LANGUAGES; do
		subtitle_tracks=$(echo "$file_streams" | jq -r --arg lang "$language" '.[] | select(.codec_type == "subtitle" and .language == $lang) | .index')
		if [ -n "$subtitle_tracks" ]; then
			subtitle_language="$language"
			subtitle_tracks_count=$(echo "$subtitle_tracks" | grep -c '[^[:space:]]')
			# Prefer select professional subtitles.
			if [ "$subtitle_tracks_count" -gt 1 ]; then
				# "i" makes the regex case-insensitive. Matches "prof", "Prof", "PROF", etc.
				profesional_subtitle_tracks="$(echo "$file_streams" | jq -r --arg lang "$language" '.[] | select(.codec_type == "subtitle" and .title != null and .language == $lang) | select(.title | test("prof|Проф"; "i")) | .index')"
				if [ -n "$profesional_subtitle_tracks" ]; then
					subtitle_tracks="$profesional_subtitle_tracks"
					subtitle_tracks_count=$(echo "$subtitle_tracks" | grep -c '[^[:space:]]')
					if [ "$subtitle_tracks_count" -gt 1 ]; then
						# Prefer select subrip over hdmv_pgs_subtitle for professional subtitles.
						profesional_subtitle_tracks="$(echo "$file_streams" | jq -r --arg lang "$language" '.[] | select(.codec_type == "subtitle" and .title != null and .language == $lang and .codec_name == "subrip") | select(.title | test("prof|Проф"; "i")) | .index')"
							if [ -n "$profesional_subtitle_tracks" ]; then
								subtitle_tracks="$profesional_subtitle_tracks"
								subtitle_tracks_count=$(echo "$subtitle_tracks" | grep -c '[^[:space:]]')
							fi
					fi
				else
					# Prefer select subrip over hdmv_pgs_subtitle for not professional subtitles.
					subrip_subtitle_tracks=$(echo "$file_streams" | jq -r --arg lang "$language" '.[] | select(.codec_type == "subtitle" and .language == $lang and .codec_name == "subrip") | .index')
					if [ -n "$subrip_subtitle_tracks" ]; then
						subtitle_tracks="$subrip_subtitle_tracks"
					fi
				fi
				unset profesional_subtitle_tracks subtitle_tracks_count subrip_subtitle_tracks subrip_subtitle_tracks
			fi
			
			break
		fi

		# Do not include fall back languages.
		if [ "$audio_language" = "$language" ]; then
			break
		fi
	done

	# Import subtitle track title from existing file.
	if [ -f "$destination" ] && [ -n "$destination_file_streams" ] && [ "$subtitle_tracks_count" -eq "1" ]; then
		# Count existing destination subtitles count.
		destination_subtitle_titles="$(echo "$destination_file_streams" | jq -r --arg lang "$subtitle_language" '.[] | select(.codec_type == "subtitle" and .language == $lang and .title != null) | .title')"
		destination_subtitle_titles_count=$(echo "$destination_subtitle_titles" | grep -c '[^[:space:]]')
		source_subtitle_title="$(echo "$file_streams" | jq -r --arg lang "$subtitle_language" '.[] | select(.codec_type == "subtitle" and .language == $lang and .title != null) | .title')"
		if [ -z "$source_subtitle_title" ] && [ "$destination_subtitle_titles_count" -eq 1 ]; then
			printf 'Source subtitle track %s, lang:%s does not have title. Overwrite it from destination file with "%s"? [y/N] ' "$subtitle_tracks" "$subtitle_language" "$destination_subtitles_titles"
			read -r transfer_subtitle_title_user_choice
			case "$transfer_subtitle_title_user_choice" in
				y|Y)
					source_subtitle_index="$subtitle_tracks"
					destination_subtitle_title="$destination_subtitle_titles"
					# Transfer subttle title to file_streams.
					file_streams=$(echo "$file_streams" | jq --arg index "$source_subtitle_index" --arg title "$destination_subtitles_title" '.[] |= if .index == ($index | tonumber) then .title = $title else . end')
					;;
				*)
					unset source_subtitle_index destination_subtitles_title
					;;
			esac
			unset transfer_subtitle_title_user_choice
		fi
	fi
	unset source_subtitle_title destination_subtitle_titles destination_subtitle_titles_count 

	# Select commentary subtitles.
	commentary_subtitle=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "subtitle" and .title != null) | select(.title | contains("Commentary"))')
	if [ -n "$commentary_subtitle" ]; then
		# Select commentary subtitles by languages.
		for language in $LANGUAGES; do
			if [ "$language" != "$subtitle_language" ];then
				commentary_subtitle_tracks=$(echo "$commentary_subtitle" | jq -r --arg lang "$language" '. | select(.language == $lang) | .index')
				if [ -n "$commentary_subtitle_tracks" ]; then
					if [ -n "$subtitle_tracks" ]; then
						subtitle_tracks="$subtitle_tracks $commentary_subtitle_tracks"
					else
						subtitle_tracks="$commentary_subtitle_tracks"
					fi
					break
				fi
			fi
		done
		unset language commentary_subtitle commentary_subtitle_tracks
	fi

	# If not found preferred audio and subtitles languages then take all subtitles.
	if [ -z "$audio_language" ] && [ -z "$subtitle_language" ]; then
		subtitle_tracks=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "subtitle") | .index')
	fi
	unset audio_language subtitle_language

	# Do not output video.
	if $NO_VIDEO_FLAG; then
		ffmpeg_command="-vn"
		# Add video and remove title.
	elif [ -n "$video_codecs" ]; then
		selected_video_tracks="$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "video" and .codec_name != "mjpeg" and .codec_name != "jpeg" and .codec_name != "png") | .index')"
		destination_video_track_index=0
		for selected_video_track in $selected_video_tracks; do
			ffmpeg_command="-map 0:V:$selected_video_track -c:V:$destination_video_track_index copy -metadata:s:v:$destination_video_track_index title=\"\""
			destination_video_track_index=$(( destination_video_track_index + 1 ))
		done
		ffmpeg_command="$ffmpeg_command -metadata title=\"\""
		unset destination_video_track_index selected_video_track
	fi

	# Map audio tracks.
	for audio_track in $selected_audio_tracks; do
		ffmpeg_command="$ffmpeg_command -map 0:$audio_track"
	done

	# Add audio tracks.
	destination_audio_track_index=0
	# Count how much audio and subtitles tracks will be copied without conversation.
	not_changed_tracks=0
	for audio_track in $selected_audio_tracks; do
		audio_codec="$(echo "$file_streams" | jq -r --arg audio_track "$audio_track" '.[$audio_track|tonumber].codec_name')"

		# Check if a audio codec is supported.
		audio_codec_supported=false
		for supported_codec in $SUPPORTED_AUDIO_CODECS; do
			if [ "$audio_codec" = "$supported_codec" ]; then
				audio_codec_supported=true
				break
			fi
		done
		unset supported_codec

		# Decide convert or copy audio track.
		if $video_codec_supported || [ -z "$video_codecs" ] || $NO_VIDEO_FLAG; then
			if $audio_codec_supported; then
				ffmpeg_command="$ffmpeg_command -c:a:$destination_audio_track_index copy"
				not_changed_tracks=$(( not_changed_tracks + 1 ))
			else
				ffmpeg_command="$ffmpeg_command -c:a:$destination_audio_track_index $CONVERT_AUDIO_CODEC"
				# Change codec name for destination screen output.
				file_streams=$(echo "$file_streams" | jq --arg index "$audio_track" --arg codec_name "$CONVERT_AUDIO_CODEC" '.[] |= if .index == ($index | tonumber) then .codec_name = $codec_name else . end')
			fi
		else
			ffmpeg_command="$ffmpeg_command -c:a:$destination_audio_track_index copy"
			not_changed_tracks=$(( not_changed_tracks + 1 ))
		fi

		destination_audio_track_index=$(( destination_audio_track_index + 1 ))

		# Change audio title from existing destination file.
		if [ -n "$source_audio_index" ] && [ "$source_audio_index" -eq "$audio_track" ] && [ -n "$destination_audio_title" ]; then
			ffmpeg_command="$ffmpeg_command -metadata:s:a=$destination_audio_track_index title=\"$destination_audio_title\""
			not_changed_tracks=$(( not_changed_tracks - 1 ))
		fi
	done
	unset audio_track audio_codec destination_audio_track_index video_codecs video_codec_supported source_audio_index destination_audio_title

	# Add subtitles to FFmpeg command.
	if [ -n "$subtitle_tracks" ]; then
		destination_subtitle_track_index=0
		for subtitle_track in $subtitle_tracks; do
			# Do not convert subtitles.
			ffmpeg_command="$ffmpeg_command -map 0:$subtitle_track -c:s copy"
			not_changed_tracks=$(( not_changed_tracks + 1 ))

			# Change subtitle title from existing destination file.
			if [ -n "$source_subtitle_index" ] && [ "$source_subtitle_index" -eq "$subtitle_track" ] && [ -n "$destination_subtitles_title" ]; then
				ffmpeg_command="$ffmpeg_command -metadata:s:s=$destination_subtitle_track_index title=\"$destination_subtitle_title\""
				not_changed_tracks=$(( not_changed_tracks - 1 ))
			fi
			destination_subtitle_track_index=$(( destination_subtitle_track_index + 1 ))
		done
		unset subtitle_track destination_subtitle_track_index destination_subtitles_title
	fi

	# Count source audio and subtitles tracks.
	audio_and_subtitle_count=$(echo "$file_streams" | jq -r '.[] | select(.codec_type == "audio" or .codec_type == "subtitle") | .index' | grep -c '[^[:space:]]')

	# Check need of conversation audio or strip some tracks.
	if [ "$not_changed_tracks" -eq "$audio_and_subtitle_count" ]; then
		#	Convert files even no changes will be made to file exept renaming and copying to destination.
		if ! $SKIP_FLAG || $NO_VIDEO_FLAG; then
			# Copy the file with ffmpeg.
			if $NO_VIDEO_FLAG; then
				# Copy without video tracks.
				ffmpeg_command="-vn -c copy"
			else
				# Copy with video tracks.
				ffmpeg_command="-c copy -metadata:s:v title=\"\""
			fi
		else
			error "Skipping (${1#"$source_directory"}) because do not need to convert this file."
			unset ffmpeg_command audio_and_subtitle_count selected_video_tracks selected_audio_tracks subtitle_tracks file_streams
			return 1
		fi
	fi

	selected_destination_tracks="$selected_video_tracks $selected_audio_tracks $subtitle_tracks"
	unset selected_video_tracks selected_audio_tracks subtitle_tracks audio_and_subtitle_count

	# Construct the destination file output jq command.
	for selected_destination_track in $selected_destination_tracks; do
	# Append selected indexes to jq command.
		if [ -n "$json_query_command" ]; then
			json_query_command="$json_query_command,$selected_destination_track"
		else 
			json_query_command="$selected_destination_track"
		fi
	done
	unset selected_destination_track selected_destination_tracks

	# Output destination file information.
	json_query_command='[ "ID:", "CODEC:", "TYPE:", "LANGUAGE:", "TITLE:"], (.['"$json_query_command] | {index: .index, codec_name: .codec_name, codec_type: .codec_type, language: .language, title: .title} | [.index, .codec_name, .codec_type, .language, .title]) | @tsv"
	echo
	echo "Destination file: $destination"
	echo "$file_streams" | eval "jq -r '$json_query_command'" | awk -F '\t' '{printf "%-3s %-17s %-9s %-9s %-0s\n", $1, $2, $3, $4, $5}'
	unset file_streams json_query_command

	# Check if source and destination are the same.
	if [ "$source" -ef "$destination" ] && ! $TEST_FLAG; then
		error "Source and destination cannot be the same file (${source#"$source_directory"})."
		return 1
	fi

	ffmpeg_command="-hide_banner -xerror -loglevel warning -stats -analyzeduration 2147483647 -probesize 2147483647 -i \"$source\" $ffmpeg_command \"$destination\""

	# Do not prompt ffmpeg to overwrite existing files.
	allow_run_ffmpeg=true 
	if $OVERWRITE_FLAG; then
		ffmpeg_command="-y $ffmpeg_command"
	# Do not overwrite existing files when skipping files.
	elif $SKIP_FLAG; then
		ffmpeg_command="-n $ffmpeg_command"
	# Overide ffmpeg interactive file overwrite prompt, because it not return error when select "N".
	elif [ -f "$destination" ] && ! $TEST_FLAG; then
		echo
		printf "File '%s' already exists. Overwrite? [y/N]" "$destination"
		read -r file_overwrite_user_choice
		case "$file_overwrite_user_choice" in
			y|Y)
				ffmpeg_command="-y $ffmpeg_command"
				allow_run_ffmpeg=true
				;;
			*)
				ffmpeg_command="-n $ffmpeg_command"
				allow_run_ffmpeg=false
				;;
		esac
		unset file_overwrite_user_choice
	fi

	ffmpeg_command="ffmpeg $ffmpeg_command"
	echo
	echo "$ffmpeg_command"

	# Record the FFmpeg start time also for dry run.
	ffmpeg_start_time=$(date +%s)

	if ! $TEST_FLAG; then
		# Create not existing destination directory.
		output_directory=$(dirname "$destination")
		if [ ! -d "$output_directory" ] && $allow_run_ffmpeg; then
			create_directory_command="mkdir -p \"$output_directory\""
			# Create directory and check for errors.
			if ! eval "$create_directory_command";then
				error "FFmpeg cannot create file in not existing directory. Skipping (${source#"$source_directory"}) file."
				unset allow_run_ffmpeg create_directory_command output_directory
				return 1
			fi
			unset create_directory_command output_directory
		fi

		# Run FFmpeg command and check FFmpeg errors.
		if ! eval "$ffmpeg_command" || ! $allow_run_ffmpeg;then
			# Record the FFmpeg end time.
			ffmpeg_end_time=$(date +%s)
			ffmpeg_run_time=$((ffmpeg_end_time - ffmpeg_start_time))
			if $allow_run_ffmpeg;then
				error "$ffmpeg_command"
			else
				error "$ffmpeg_command" "do not print"
			fi
			unset ffmpeg_command allow_run_ffmpeg
			return 1
		fi
		if ! $NO_VIDEO_FLAG; then
			for source_nfo_file in .nfo movie.nfo tvshow.nfo;do
				# Create source and destination nfo file path.
				if [ "$source_nfo_file" = ".nfo" ]; then
					destination_nfo_file="${destination%.*}$source_nfo_file"
					source_nfo_file="${source%.*}$source_nfo_file"
				else
					destination_nfo_file="$destination_directory$source_nfo_file"
					source_nfo_file="$source_directory$source_nfo_file"
				fi

				# Clean source nfo file.
				if [ -f "$source_nfo_file" ]; then
					if command -v xmlstarlet > /dev/null 2>&1; then
						if xmlstarlet ed \
						-d '//*[not(node())]' \
						-d '//videoassettitle' \
						-d '//videoassetid' \
						-d '//videoassettype' \
						-d '//hasvideoversions' \
						-d '//hasvideoextras' \
						-d '//isdefaultvideoversion' \
						-d '//resume' \
						-d '//userrating' \
						-d '//watched' \
						-d '//playcount' \
						-d '//lastplayed' \
						-d '//ratings/rating[@name="NFO"]' \
						-d '//top250[text()="0"]' \
						-d '//isuserfavorite[text()="false"]' \
						-d '//outline[contains(//plot/text(), .)]' \
						-d '//fileinfo' \
						-d '//source[text()="UNKNOWN"]' \
						-d '//edition[text()="NONE"]' \
						-d '//mpaa[text()="Not Rated"]' \
						-d '//certification[text()="Not Rated"]' \
						-d '//mpaa[text()="NR"]' \
						-d '//certification[text()="NR"]' \
						-d '//original_filename' \
						-d '//user_note' \
						"$source_nfo_file" > "$destination_nfo_file"; then
							echo "Clean $destination_nfo_file"
							echo "rm $source_nfo_file"
							rm "$source_nfo_file"
						else
							error "Failed clean $source_nfo_file"
						fi
						### 📌 **Explanation of Commands**
						# Here’s what each `xmlstarlet ed -d` command does:
						# | `-d '//*[not(node())]'` | Remove **empty elements** (tags with no text and no children, like `<trailer/>` or `<empty></empty>`). |
						# | `-d '//ratings/rating[@name="NFO"]'` | Remove `<rating>` elements with `@name="NFO"`. |
						# | `-d '//top250[text()="0"]'` | Remove `<top250>` elements with value `0`. |
						# | `-d '//outline[contains(//plot/text(), .)]'` | Remove `<outline>` elements that are **substrings** of the `<plot>` text. |
						# | `-d '//fileinfo'` | Remove `<fileinfo>` elements. |
						# | `-d '//source[text()="UNKNOWN"]'` | Remove `<source>` elements with value `UNKNOWN`. |

					else
						error "xmlstarlet is not installed. Cannot clean $source_nfo_file"
					fi
				fi
			done
			unset source_nfo_file destination_nfo_file

			# move all kodi files that names begin same as file name.
			escaped_source_file_name=$(echo "$source_file_name" | sed 's/\[/\\[/g')			# Escape [
			escaped_source_file_name=$(echo "$escaped_source_file_name" | sed 's/\]/\\]/g')	# Escape ]
			escaped_source_file_name=$(echo "$escaped_source_file_name" | sed 's/\*/\\*/g')	# Escape *
			escaped_source_file_name=$(echo "$escaped_source_file_name" | sed 's/\?/\\?/g')	# Escape ?

			kodi_files=$(find "$source_directory" -maxdepth 1 -type f -name "$escaped_source_file_name*" -not -name "$escaped_source_file_name.$source_extension")
			unset escaped_source_file_name source_extension

			if [ -n "$kodi_files" ]; then
				#IFS` determines which characters separate the fields in each line of data.
				SAVE_IFS=$IFS
				IFS="$(printf '\n\t')" #Change Internal Field Separator to newline or tab. Why do not work with only '\n'?

				for kodi_file in $kodi_files; do
					# Extract the relative path and construct destination path.
					kodi_file_destination="${kodi_file#"${source%.*}"}"
					kodi_file_destination="${destination%.*}$kodi_file_destination"
						move_file_command="mv -f \"$kodi_file\" \"$kodi_file_destination\""
						echo "$move_file_command"
						if ! eval "$move_file_command";then
							# Record move kodi files error.
							error "moving \"$kodi_file\" file."
						fi
				done
				IFS=$SAVE_IFS
				unset kodi_files kodi_file move_file_command kodi_file_destination SAVE_IFS
			fi

			# move kodi files that does not start same as file name.
			kodi_files=$(find "$source_directory" -maxdepth 1 -type f \( -name tvshow.nfo \
				-o -name "poster.*" \
				-o -name "movie.*" \
				-o -name "folder.*" \
				-o -name "cover.*" \
				-o -name "fanart*" \
				-o -name "backdrop*" \
				-o -name "banner.*" \
				-o -name "clearart.*" \
				-o -name "disc.*" \
				-o -name "discart.*" \
				-o -name "thumb.*" \
				-o -name "landscape.*" \
				-o -name "clearlogo.*" \
				-o -name "logo.*" \
				-o -name "keyart.*" \
				-o -name "characterart.*" \
				-o -name "season*" \
				-o -name "tvshow-trailers.*" \
				-o -name "trailer.*" \))

			if [ -n "$kodi_files" ];then

				#IFS` determines which characters separate the fields in each line of data.
				SAVE_IFS=$IFS
				IFS="$(printf '\n\t')" #Change Internal Field Separator to newline or tab. Why do not work with only '\n'?

				for kodi_file in $kodi_files; do
					kodi_file_destination="$destination_directory"$(basename "$kodi_file")
					move_file_command="mv -f \"$kodi_file\" \"$kodi_file_destination\""
					echo "$move_file_command"
					if ! eval "$move_file_command";then
						error "moving \"$kodi_file\" file."
					fi
				done
				IFS=$SAVE_IFS
				unset kodi_files kodi_file move_file_command kodi_file_destination SAVE_IFS
			fi

			# Move kodi folders.
			for kodi_folder in .actors/ trailers/ extrafanart/; do
				if [ -d "$source_directory$kodi_folder" ]; then
					move_file_command="rsync -av --remove-source-files \"$source_directory$kodi_folder\" \"$destination_directory$kodi_folder\""
					echo "$move_file_command"
					if eval "$move_file_command";then
						rmdir "$source_directory$kodi_folder"
					else
						error "moving \"$source_directory$kodi_folder\" folder."
					fi
				fi
			done
			unset kodi_folder move_file_command
		fi
	else
		# Register all successful fmmpeg commands.
		messages_without_mistakes="$messages_without_mistakes$ffmpeg_command\n"
		# ffmpeg command execution time with error or dry run.
		ffmpeg_end_time=$(date +%s)
		ffmpeg_run_time=$((ffmpeg_end_time - ffmpeg_start_time))
		return 1
	fi

	# Successful FFmpeg end time.
	ffmpeg_end_time=$(date +%s)

	# Calculate the difference in seconds.
	ffmpeg_run_time=$((ffmpeg_end_time - ffmpeg_start_time))
	# Format the execution time using date command.
	formatted_time=$(date -u -d @"$ffmpeg_run_time" +"%T")
	# Output time in format hours:minutes:seconds how long took function and how long took whole script to finish.

	# Compare source and destination files after conversation.
	if [ -f "$destination" ]; then
		destination_size=$(stat "$destination" | grep "Size:" | awk '{print $2}')
	else
		destination_size=0
	fi

	# Check if the destination file is bigger than the source file.
	if [ "$destination_size" -gt "$source_size" ]; then
		error "Destination file (${destination#"$input_destination"}) is bigger than source file (${source#"$source_directory"})."
		return 1
	fi

	# Check if the destination file is less than 10% of the source file size.
	ten_percent=$((source_size / 10))
	if [ "$destination_size" -lt "$ten_percent" ] || [ "$destination_size" -eq 0 ] && ! $NO_VIDEO_FLAG; then
		error "Destination file (${destination#"$input_destination"}) is less than 10%% of the source file. Deleting it."

		# Delete destination file.
		if [ -f "$destination" ]; then
			rm "$destination"
		fi
		return 1
	fi
	unset ten_percent

	# Make destination file modification date same as source.
	if [ -f "$destination" ]; then
		touch -r "$source" "$destination"
	else
		error "Destination file (${destination#"$input_destination"}) does not exist."
		return 1
	fi

	# Calculate the difference in sizes.
	size_difference=$((source_size - destination_size))
	unset source_size destination_size

	# Output saved disk size of every file.
	if [ "$size_difference" -gt 0 ]; then
		saved_size="Saved: $(human_readable_size "$size_difference") and it took $formatted_time to do so."
		printf '\e[92m%s\e[0m\n' "$saved_size"
	else
		error "${destination#"$input_destination"} is same size as source"
		return	1
	fi

	# Register all successful FFmpeg commands.
	messages_without_mistakes="$messages_without_mistakes$ffmpeg_command\n$saved_size\n"
	unset ffmpeg_command saved_size

	# Update the total saved bytes.
	total_size_difference=$((total_size_difference + size_difference))
	unset size_difference
}

# Function to check a file for errors.
check_file(){
	echo "Source file is: $1"

	# Record the FFmpeg start time.
	ffmpeg_start_time=$(date +%s)

	#eval ffmpeg -err_detect explode -v error -hide_banner -i \"$1\" -c copy -f null - 2>&1 >/dev/null
	# Run ffmpeg and capture its output and exit status
	#without video
	#ffmpeg_output=$(ffmpeg -v error -i "$1" -vn -f null - 2>&1)
	#ffmpeg_output=$(ffmpeg -v error -xerror -err_detect explode -i "$1" -f null - 2>&1)
	#ffmpeg -xerror -err_detect explode -hide_banner -i "$1" -f null -
	#ffmpeg -hwaccels -hide_banner #shows GPU accelerators.
	#ffmpeg -hwaccel vaapi -vaapi_device /dev/dri/renderD128 -xerror -err_detect explode -hide_banner -i "$1" -f null - #works 10x slower

# Shows ffmpeg status but do not catch all errors
# + no hwaccel = 40 fps
# + vdpau 126 fps
# + cuda 100 fps
# + vaapi 39 fps
# - qsv no hevc
# - drm no hevc
# - opencl -hwaccel_device 0 - 40 fps
# + vulkan 97 fps Unrecognized hwaccel: vulcan
# + nvdec 120 fps
	ffmpeg_command="ffmpeg -hide_banner -hwaccel vdpau -xerror -err_detect explode -analyzeduration 2147483647 -probesize 2147483647 -i \"$1\" -f null -" #vdpau works faster than cuda and nvdec.
	echo "$ffmpeg_command"

	if ! $TEST_FLAG; then
		#Run FFmpeg command and check FFmpeg errors.
		if ! eval "$ffmpeg_command";then
			# Record the FFmpeg end time.
			ffmpeg_end_time=$(date +%s)
			ffmpeg_run_time=$((ffmpeg_end_time - ffmpeg_start_time))
			formatted_time=$(date -u -d @"$ffmpeg_run_time" +"%T")
			error "$1. Check took $formatted_time"
			unset ffmpeg_command ffmpeg_start_time ffmpeg_end_time ffmpeg_run_time formatted_time 
			return 1
		else
			ffmpeg_end_time=$(date +%s)
			ffmpeg_run_time=$((ffmpeg_end_time - ffmpeg_start_time))
			formatted_time=$(date -u -d @"$ffmpeg_run_time" +"%T")

			printf '\e[92m✅ %s. Check took %s to do so.\e[0m\n' "$1" "$formatted_time"
			messages_without_mistakes="$messages_without_mistakes$1\n"
			unset ffmpeg_command ffmpeg_start_time ffmpeg_end_time ffmpeg_run_time formatted_time
		fi
	else
		# Dry run. Do nothing.
		messages_without_mistakes="$messages_without_mistakes$1\n"
		ffmpeg_end_time=$(date +%s)
		ffmpeg_run_time=$((ffmpeg_end_time - ffmpeg_start_time))
		unset ffmpeg_command ffmpeg_start_time ffmpeg_end_time ffmpeg_run_time
	fi
}

# Function to process files in a directory recursively.
process_directory() {
	source="$1"
	# Loop through files and sub folders in the folder.
	for path in "$source"*; do
		if [ -d "$path" ]; then
			# Recursively process sub folders.
			process_directory "$path/"
		elif [ -f "$path" ]; then
			# Check if a file has a valid extension.
			file_extension=".${path##*.}"
			for extension in $EXTENSIONS; do
				if [ "$extension" = "$file_extension" ]; then
					# Print horizontal file separator line.
					if [ -n "$job_separator" ]; then
						echo "$job_separator"
					else
						# Generate default lenght job separator.
						job_separator=$(printf '%*s' "$terminal_columns" " " | tr ' ' '-')
					fi

					# Change job separator lenght by terminal width.
					if $TPUT_EXIST; then
						if [ "$(tput cols)" -ne "$terminal_columns" ]; then
							terminal_columns=$(tput cols)
							job_separator=$(printf '%*s' "$terminal_columns" " " | tr ' ' '-')
						fi
					fi

					# Set same folder for destination as source.
					directory=$(dirname "$path")
					folder="${directory#"$user_source_directory"}"
					if [ "$directory" = "$folder" ]; then
						unset folder
					fi
					unset directory

					# Count processed files.
					processed_files_count=$(( processed_files_count + 1 ))

					# Determine the operation based on --check parameter.
					if $CHECK_FLAG; then
						# Check files for errors.
						check_file "$path"
					else
						if [ -n "$folder" ];then
							destination="$input_destination$folder/"
						else
							destination="$input_destination"
						fi
						unset folder
						# Convert file.
						convert_file "$path" "$destination"
						unset destination
					fi
				break # Valid extension found.
				fi
			done
			unset extension
		fi
		unset folder
	done
	unset path
}

# Program beginning:
# Check essential programs for script.
for program in ffprobe ffmpeg jq; do
	if ! command -v "$program" > /dev/null 2>&1; then
		error "$program is not installed. Please install it first"
		exit 1
	fi
done

# Check if exist tput program.
if command -v "tput" > /dev/null 2>&1; then
	TPUT_EXIST=true
else
	TPUT_EXIST=false
fi

# Load config variables from file arpas.cfg
print_config_error=true
config_file="${0%.*}.cfg"
if [ -f "$config_file" ];then
	. "$config_file"
else
	# Print error only when not given -h or --help script argument.
	for script_argument in "$@"; do
		if [ "$script_argument" = "-h" ] || [ "$script_argument" = "--help" ]; then
			print_config_error=false
			break
		fi
	done
	if $print_config_error ;then 
		printf 'Do not found configuration file %s.\n' "$config_file"
	fi
fi
unset script_argument config_file

# Fallback constants declaration:
set_default_variables "constant string" DEFAULT_SOURCE "/path/folder/" # or /path/folder/file.ext, used when not given with script parameters.
set_default_variables "constant string" DEFAULT_MOVIE_DESTINATION "/path/to/movie/folder/" # Default destination for movie. Can be directory. Used when not given with script parameters.
set_default_variables "constant string" DEFAULT_TV_SHOWS_DESTINATION "/path/to/TV show/folder/" # Default TV series directory. Used when not given with script parameters.
set_default_variables "constant string" LANGUAGES "lit eng rus" # Preferred and fallback languages. Script chooses language from left to right.
set_default_variables "constant string" CONVERT_AUDIO_CODEC libvorbis # Audio codec to convert unsupported codecs.
set_default_variables "variable string" EXTENSIONS ".mkv .avi .mka .mp4 .m2ts .ts" # Script supported file extensions.
set_default_variables "constant string" SUPPORTED_VIDEO_CODECS "h264 hevc av1 vp9 vp8" # Convert audio with these video codecs.
set_default_variables "constant string" SUPPORTED_AUDIO_CODECS "vorbis aac mp3 opus flac" # Do not convert audio with these audio codecs.

# Set default source and destination.
source="$DEFAULT_SOURCE"
destination="$DEFAULT_TV_SHOWS_DESTINATION"

# Handle user parameters.
while [ $# -gt 0 ]; do
	case "$1" in
		-a|--audio)
			shift
			# Collect numeric parameters for the -a flag.
			while [ $# -gt 0 ] && echo "$1" | grep -q '^[0-9]*$'; do
				if [ -z "$audio_track_user_choice" ]; then
					AUDIO_FLAG=true
					audio_track_user_choice=$1
				else
					audio_track_user_choice="$audio_track_user_choice $1"
				fi
				shift
			done
			;;
		-c|--check)
			CHECK_FLAG=true
			shift
			;;
		-d|--debug)
			shift
			;;
		-h|--help)
			echo "Usage:"
			echo "$(basename "$0") [-a index [index ...]] [-c] [-d] [-o] [-s] [-t] [-v] [source] [destination]"
			echo "  -a, --audio		Specify audio tracks (space-separated list of FFmpeg indexes)."
			echo "  -c, --check		Checks file for errors."
			echo "  -d, --debug		Enables script debugging."
			echo "  -o, --overwrite	Overwrite all existing destination media files without prompt for each file."
			echo "  -s, --skip		Skip files that do not need audio/subtitle conversation/removal."
			echo "  -t, --test		Print only FFmepg commands (dry run)."
			echo "  -v, --video		Excludes video. Output only audio and subtitles."
			echo "  If no source or destination are provided then defaults are used."
			echo "  Default source is: $DEFAULT_SOURCE"
			echo "  Default destination for movies is: $DEFAULT_MOVIE_DESTINATION"
			echo "  Default destination for TV shows is: $DEFAULT_TV_SHOWS_DESTINATION"
			echo "  If one parameter is provided, it is considered as the source."
			echo "  If two parameters are provided the first is source, second is destination."
			echo "  Source can be file or directory."
			echo "  Destination can be only directory."
			echo "  Supported files extensions: $EXTENSIONS"
			echo "  Languages selection priority:"
			for language in $LANGUAGES;do
				language_number=$((language_number + 1))
				printf "\t\t\t\t%s\n" "$language_number. $language"
			done
			echo "Examples:"
			echo "  $(basename "$0")			# Use default source and destination."
			echo "  $(basename "$0") source		# Use specified source and default destination."
			echo "  $(basename "$0") -c source		# Check specified source for errors."
			echo "  $(basename "$0") -a 1 3 source	# Select 1 and 3 audio tracks. Use specified source and default destination."
			echo "  $(basename "$0") -v -a 0 source	# Use specified source and default destination to output all audio tracks (without video and do not prompt user choice)."
			echo "  $(basename "$0") -t source		# Dry run without actual conversation."
			echo "  $(basename "$0") -s source destination # Skip files and use specified source and destination."
			exit 0
			;;
		-o|--overwrite)
			OVERWRITE_FLAG=true
			shift
			;;
		-s|--skip)
			SKIP_FLAG=true
			shift
			;;
		-t|--test)
			TEST_FLAG=true
			shift
			;;
		-v|--video)
			NO_VIDEO_FLAG=true
			shift
			;;
		*)
			if [ $# -eq 1 ]; then
				# One parameter provided, use it as the source.
				source=$1
			elif [ $# -eq 2 ]; then
				# Two parameters provided, use the first as the source and the second as the destination.
				source="$1"
				destination="$2"
			else
				# More than two parameters provided, treat as error.
				echo "⚠️ Error in given arguments:"
				for script_argument in "$@"; do
					argument_number=$(( argument_number + 1 ))
					echo "$argument_number. $script_argument"
				done
				echo
				echo "$(basename "$0") --help"
				exec "$0" --help
				exit 1
			fi
			break
	esac
done
unset language script_argument argument_number language

# Confirm if the last character of $input_destination is '/'.
input_destination=$(confirm_last_character "$destination" "/")

# Fallback global variables declaration.
set_default_variables integer terminal_columns 80 # Terminal text width in symbols. Used when tput not exist.
set_default_variables "numerical list" audio_track_user_choice # User chosen audio tracks list.
set_default_variables boolean OVERWRITE_FLAG false # Overwrite media files.
set_default_variables boolean CHECK_FLAG false # Check files for errors.
set_default_variables boolean NO_VIDEO_FLAG false # Output only audio and subtitles.
set_default_variables boolean TEST_FLAG false # Dry run conversation.
set_default_variables boolean AUDIO_FLAG false # Select only preferred audio tracks.
set_default_variables boolean SKIP_FLAG false # Skip files that do not need audio/subtitle conversation/removal.
unset var_type var_name default_value print_config_error

# Check more file extensions than convert.
if $CHECK_FLAG; then
#	echo "Run ffmpeg -formats and extract the formats. Please wait..."
#	# Run ffmpeg -formats and extract the formats
#	EXTENSIONS=$(ffmpeg -demuxers -hide_banner | tail -n +5 | cut -d' ' -f4 | xargs -i{} ffmpeg -hide_banner -h demuxer={} | grep 'Common extensions' | cut -d' ' -f7 | tr ',' $'\n' | tr -d '.'))
#	# Because very slow extract formats it is faster use baked variable.
	EXTENSIONS=".mkv .avi .mp4 .mka .aac .ac3 .mov .mp2 .mp3 .ogg .vc1 .dss .dts .eac3 .flac .flv .hevc .m2a .m4a .m4v .mks .3g2 .3gp .aa3"
fi

# Check if user given source is file or directory.
if [ -f "$source" ]; then
	user_source_directory=$(dirname "$source")"/"
	process_directory "$source"
	exit 0 # Exit without messages output.
# If source is directory then remember user file paths.
elif [ -d "$source" ]; then
	# Confirm if the last character of $source is '/'.
	source=$(confirm_last_character "$source" "/")

	# Directories inputted by user or defaults.
	user_source_directory="$source"
	process_directory "$source"
else
	printf '\e[38;5;196m⚠️ "%s" does not exist or is not a media file. Use media files with these %s extensions or directory with media files.\e[0m\n' "$source" "$EXTENSIONS"
	exit 1
fi

# Output messages only if more than 1 file processed.
if [ "$processed_files_count" -gt 1 ]; then

	# Output successful FFmpeg commands.
	if [ -n "$messages_without_mistakes" ]; then
		echo "$job_separator"
		if $CHECK_FLAG; then
			echo "✅ Successful checks:"
		elif $TEST_FLAG; then
			echo "All FFmpeg commands:"
		else
			echo "✅ Successful conversations:"
		fi
		printf '\e[92m%b\e[0m' "$messages_without_mistakes"
	fi

	# Output files with errors.
	if [ -n "$errors" ]; then
		echo "$job_separator"
		printf 'Files with errors is:\n\e[38;5;196m%b\e[0m' "$errors"
	fi

	# Record the end time.
	script_end_time=$(date +%s)

	# Calculate the difference in seconds.
	script_execution_time=$((script_end_time - script_start_time))

	# Format the execution time using date command.
	script_execution_time=$(date -u -d @"$script_execution_time" +"%T")

	if $TEST_FLAG; then
		echo "Dry run for $processed_files_count files took $script_execution_time."
	elif $CHECK_FLAG; then
		echo "$processed_files_count files check complete in $script_execution_time"
	elif [ "$total_size_difference" -gt "$size_difference" ]; then
		echo "Total saved: $(human_readable_size "$total_size_difference") and it took $script_execution_time to do so."
	else
		echo "Do not saved anything but it took $script_execution_time to do so."
	fi
fi
