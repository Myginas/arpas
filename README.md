# arpas

Shell script for batch processing media files

## Features:
**Media File Conversion:**
- Removes unnecessary audio and subtitle tracks
- Converts unsupported audio codecs to a compatible format (default: Vorbis)

**Intelligent File Renaming - Automatically:**
- Renames files with cleaned-up, readable names
- Normalizes TV series names to standard format (S##E## pattern)
- Normalizes Movies names to movie name (release years)
- Cleans up special characters and formatting

**Smart Track Selection:**
- Selects preferred audio/subtitle languages in priority order (default: Lithuanian, English, Russian)
- Prefers professional audio tracks when multiple options exist
- Prioritizes SubRip subtitles over HDMV PGS format
- Supports fallback languages and commentary track inclusion

**Metadata Management:**
- Cleans NFO (metadata) files using xmlstarlet to remove unwanted tags
- Moves associated Kodi files (fanart, posters, thumbnails, etc.) to destination
- Transfers audio/subtitle titles from existing destination files
- Matches source and destination file modification dates

**File Organization:**
- Handles both single files and directories (recursively)
- Automatically organizes files into TV shows or movie folders based on detected patterns
- Loads settings from optional _arpas.cfg configuration file

## Requirements:

- ffmpeg (https://ffmpeg.org/)
- jq (command-line JSON processor)

## Optional:

- xmlstarlet (command-line tool for processing kodi nfo files)
- rsync (is in kodi virtual.network-tools addon)

## Usage

```sh
./arpas.sh [OPTIONS] [source] [destination]
```

If no parameters are provided, default source and destination are used.
If you provide a directory, all media files in that directory will be processed.

**Example:**

```bash
./arpas.sh /path/to/your/videos
```

## Customization

You can edit `_arpas.cfg` to adjust which codecs or languages to keep. The script is annotated for easy modification.

### Options

- -a, --audio         Specify audio tracks (space-separated list of FFmpeg indexes)
- -c, --check         Checks file for errors
- -d, --debug         Enables script debugging
- -o, --overwrite     Do not prompt for overwriting existing files
- -s, --skip          Skip files that do not need audio/subtitle conversation/removal
- -t, --test          Print only FFmpeg commands (dry run)
- -v, --video         Excludes video (output only audio and subtitles)
- --verbose           Print additional config errors
- -h, --help          Show usage instructions

### Examples

- Use default source and destination:
  ```sh
  ./arpas.sh
  ```

- Process a specific file:
  ```sh
  ./arpas.sh /path/to/video.mkv /path/to/destination/
  ```

- Process a directory:
  ```sh
  ./arpas.sh /path/to/videos/
  ```

- Check a file for errors only:
  ```sh
  ./arpas.sh -c /path/to/video.mkv
  ```

- Select specific audio tracks:
  ```sh
  ./arpas.sh -a 1 3 /path/to/video.mkv /path/to/destination/
  ```

## License

This project is licensed under the GNU General Public License v2.0.
