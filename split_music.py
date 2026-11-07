#!/usr/bin/env python3
"""Offline MP4 to MP3, optional timestamp splitting, embedded video-frame cover."""
import argparse
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def run(args):
    subprocess.run(args, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('video', type=Path, help='Path to the original MP4')
    parser.add_argument('--cover-time', type=float, default=90, help='Cover timestamp in seconds (default: 90)')
    parser.add_argument('--whole', action='store_true', help='Keep the full compilation without splitting')
    args = parser.parse_args()
    for tool in ('ffmpeg', 'ffprobe'):
        if not shutil.which(tool):
            raise ValueError(f'{tool} not found. Install FFmpeg and reopen the terminal.')
    video = args.video.expanduser().resolve()
    if not video.is_file():
        raise ValueError(f'File not found: {video}')
    result = subprocess.run(['ffprobe', '-v', 'error', '-show_format', '-of', 'json', str(video)],
                            check=True, capture_output=True, encoding='utf-8')
    info = json.loads(result.stdout)['format']
    duration = float(info['duration'])
    if not 0 <= args.cover_time < duration:
        raise ValueError('Cover timestamp must be inside the video duration.')
    tags = {key.lower(): value for key, value in info.get('tags', {}).items()}
    description = tags.get('description') or tags.get('comment') or ''
    pattern = r'^[ \t]*\[?((?:\d{1,2}:)?\d{1,2}:\d{2})\]?[ \t]+(?:\d+[.)][ \t]*)?([^\r\n]+)'
    tracks = []
    if not args.whole:
        for match in re.finditer(pattern, description, re.MULTILINE):
            seconds = 0
            for part in match[1].split(':'):
                seconds = seconds * 60 + int(part)
            tracks.append((seconds, match[2].strip()))
    if len(tracks) < 2:
        tracks = [(0, video.stem)]
        print('Creating ONE complete MP3 with cover. No splitting.')
    else:
        for i, (start, _) in enumerate(tracks):
            if start >= duration or (i and start <= tracks[i - 1][0]):
                raise ValueError('Invalid or unordered timestamps. Use --whole to keep the complete mix.')
        print(f'Tracklist found: {len(tracks)} tracks. Last track continues to the end.')
    folder = video.parent / ('Tracks_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    folder.mkdir()
    cover = folder / 'cover.jpg'
    base = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-n']
    run(base + ['-ss', str(args.cover_time), '-i', str(video), '-map', '0:v:0',
                '-frames:v', '1', '-q:v', '2', str(cover)])
    if not cover.is_file():
        raise ValueError('Could not extract the cover frame.')
    for i, (start, title) in enumerate(tracks):
        name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', f'{i + 1:02d} - {title}')[:150].rstrip(' .')
        output = folder / (name + '.mp3')
        command = base + ['-ss', str(start), '-i', str(video), '-i', str(cover)]
        if i + 1 < len(tracks):
            command += ['-t', str(tracks[i + 1][0] - start)]
        command += ['-map', '0:a:0', '-map', '1:v:0', '-map_metadata', '-1',
                    '-c:a', 'libmp3lame', '-q:a', '2', '-c:v', 'copy',
                    '-disposition:v:0', 'attached_pic', '-id3v2_version', '3',
                    '-metadata', f'title={title}', '-metadata', f'track={i + 1}/{len(tracks)}',
                    '-metadata:s:v', 'title=Album cover',
                    '-metadata:s:v', 'comment=Cover (front)', str(output)]
        print(f'Creating: {name}')
        run(command)
    print(f'Done! Output folder: {folder}')
    if sys.platform == 'darwin':
        run(['open', str(folder)])


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        sys.exit(1)
