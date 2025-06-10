# arpas

Shell script for batch processing media files. It removes unnecessary audio and subtitle tracks, converts unsupported audio codecs, and renames files using [ffmpeg](https://ffmpeg.org/).

## Features

- Removes unnecessary audio and subtitle tracks from media files
- Converts unsupported audio codecs to a specified format (default: libvorbis)
- Renames files with cleaned-up, readable names
- Handles both single files and directories (recursively)
- Supports a wide range of video and audio file extensions
- Designed for automation with minimal user interaction

## Requirements

- [ffmpeg](https://ffmpeg.org/)
- ash (or compatible shell)

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

You can edit `arpas.sh` to adjust which codecs or languages to keep, as well as rename patterns. The script is annotated for easy modification.

### Options

- -a, --audio         Specify audio tracks (space-separated list of FFmpeg indexes)
- -c, --check         Checks file for errors
- -d, --debug         Enables script debugging
- -o, --overwrite     Do not prompt for overwriting existing files
- -s, --skip          Skip files that do not need audio/subtitle conversation/removal
- -t, --test          Print only FFmpeg commands (dry run)
- -v, --video         Excludes video (output only audio and subtitles)
- -h, --help          Show usage instructions

### Examples

- Use default source and destination:
  ```sh
  ./arpas.sh
  ```

- Process a specific file:
  ```sh
  ./arpas.sh /path/to/video.mkv
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
  ./arpas.sh -a 1 3 /path/to/video.mkv
  ```

## License

This project is licensed under the GNU General Public License v3.0. See the LICENSE file for details.
