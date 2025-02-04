# WhisperSubs

### WhisperSubs is a mpv lua script to generate subtitles at runtime with whisper.cpp on Linux

This is just a fun little side project I've been working on. So don't expect a flawless experience.

This script runs off the the cli example from the whisper.cpp project:

https://github.com/ggerganov/whisper.cpp/tree/master/examples/cli

## Dependencies

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
- [ffmpeg](https://ffmpeg.org/)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp)  (If streaming)

## Installation

Just copy the lua script in the appropriate mpv script folder.

See here for the script folder location: https://mpv.io/manual/stable/#script-location

## Usage

To toggle just use the <kbd>Ctrl + .<kbd> shortcut key.

### BUT FIRST

This script requires a little bit of setup in order to work.

Thankfully all you will need to do is modify some of the static global variables at the top of the script.

Most notably the `WHISPER_CMD` variable requires:
- Setting the whisper-cli executable location
- Pointing to the whisper.cpp model location

And optionally other things such as:
- Adjusting the amount of cpu threads used
- The language of the subtitles

Or any other command-line options as long as they don't mess with any of the input or output options.

Also modifying the `CHUNK_SIZE` is a good idea. This will always be a balancing act. Because how whisper works, sometimes when music is playing whisper will just give up at creating more subtitles.
But, this behavior is only until the end of the process chunk. What this means is that having a lower `CHUNK_SIZE` will lead to less of this terrible whisper behavior.
Although if the `CHUNK_SIZE` is too low the model won't be able to keep up AND the subs will overlap a lot more.
A `CHUNK_SIZE` too large will lead to slow first initial subtitles creation and the previous "whisper giving up" behavior for a longer period of time.

I found that 15000ms(15 secs) is the sweet spot in my testing.

You might also might want to toggle on `SHOW_PROGRESS` to see if it's keeping a good pace.
Other variables like `TMP_WAV_PATH`, `TMP_SUB_PATH`, `TMP_STREAM_PATH`, etc... you can leave as is if you like.
