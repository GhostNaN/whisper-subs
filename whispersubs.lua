local TMP_WAV_PATH = "/tmp/mpv_whisper_tmp_wav.wav"
local TMP_SUB_PATH = "/tmp/mpv_whisper_tmp_sub" -- without file ext "srt"
local TMP_STREAM_PATH = "/tmp/mpv_whisper_tmp_stream"
local WHISPER_CMD = "whisper.cpp -m /models/ggml/whisper-ggml-medium.bin --threads 6 --language en"
local CHUNK_SIZE = 15 * 1000 -- the amount of subs to process at a time in ms
local WAV_CHUNK_SIZE = CHUNK_SIZE + 1000
local INIT_POS = 0 -- starting position to start creating subs in ms
local STREAM_TIMEOUT = 15 -- timeout for init stream to start
local SHOW_PROGRESS = false

local running = false
local stream_cmd
local stream_process
local stream_downloaded = false


local function formatProgress(ms)
    local seconds = math.floor(ms / 1000)
    local minutes = math.floor(seconds / 60)
    local hours = math.floor(minutes / 60)

    local seconds = seconds % 60
    local minutes = minutes % 60
    local hours = hours % 24

    return string.format("%02d:%02d:%02d.%03d", hours, minutes, seconds, ms % 1000)
end


local function cleanup()

	os.execute('rm '..TMP_WAV_PATH, 'r')
	os.execute('rm '..TMP_SUB_PATH..'*', 'r')
	os.execute('rm '..TMP_STREAM_PATH..'*', 'r')
end


local function stop()

	if stream_process then
		stream_process:close()
	end

	cleanup()
end


local function saveSubs(media_path)

	local sub_path = media_path:match("(.+)%..+$") -- remove file ext from media
	sub_path = sub_path..'.srt'..'"' -- add the file ext back with the "

	mp.commandv('show-text', 'Subtitles finished processing: saving to'..sub_path, 5000)

	os.execute('cp '..TMP_SUB_PATH..'.srt '..sub_path, 'r')
end


local function appendSubs(current_pos)

	os.execute(WHISPER_CMD..' --output-srt -d '..CHUNK_SIZE..' -f '..TMP_WAV_PATH..' -of '..TMP_SUB_PATH..'_append', 'r')

	-- offset srt timings to current_pos
	os.execute('ffmpeg -hide_banner -loglevel error -itsoffset '..current_pos..'ms -i '..TMP_SUB_PATH..'_append.srt'..' -c copy -y '..TMP_SUB_PATH..'_append_offset.srt', 'r')

	-- Append subs manually because whisper won't
	os.execute('cat '..TMP_SUB_PATH..'_append_offset.srt'..' >> '..TMP_SUB_PATH..'.srt', 'r')

	if SHOW_PROGRESS then
		mp.commandv('show-text','Whisper Subtitles: '..formatProgress(current_pos + CHUNK_SIZE))
	end

	mp.command('sub-reload')

	return current_pos + CHUNK_SIZE
end


local function createSubs(current_pos)

	mp.commandv('show-text','Whisper Subtitles: Generating initial subtitles')

	current_pos = appendSubs(current_pos)

	mp.commandv('sub-add', TMP_SUB_PATH..'.srt')

	return current_pos
end


local function createWAV(media_path, current_pos)

	local handle = io.popen('ffmpeg -hide_banner -loglevel error -ss '..current_pos..'ms -t '..WAV_CHUNK_SIZE..'ms '..'-i '..media_path..' -ar 16000 -ac 1 -c:a pcm_s16le -y '..TMP_WAV_PATH..' 2>&1', 'r')

	if handle then
		local output = handle:read('*all')
		print(output)
		handle:close()
		if output:find 'No such file' then
			return false
		elseif output:find 'Invalid' then
			return false
		end

		return true
	else
		return false
	end
end


-- Check if the length of the wave file is long enough to be processed by CHUNK_SIZE
-- This is only really a streaming issue that is still downloading
local function isWavLongEnough(current_pos)

	local handle = io.popen("ffprobe -i "..TMP_WAV_PATH.." -show_format -v quiet | sed -n 's/duration=//p'", 'r')
	local output = handle:read('*all')
	handle:close()

	local duration = tonumber(output)

	if duration then
		if duration*1000 >= CHUNK_SIZE then
			return true;
		end
	end

	mp.commandv('show-text','Whisper Subtitles: Waiting for more stream to download', 3000)
	return false

end


-- Check if stream is still not zombie
local function checkStreamStatus()

    local handle = io.popen('ps --no-headers -o state -C "'..stream_cmd..'"', 'r')
    local output = handle:read("*all")
    handle:close()

    if output:find 'Z' then
		stream_downloaded = true;
		local output = stream_process:read('*all')
		stream_process:close()
		stream_process = nil

		mp.commandv('show-text','Whisper Subtitles: Finished downloading stream')
	end
end


local function startStream(stream_path)

	stream_cmd = 'yt-dlp --no-part -r 10M -x -o '..TMP_STREAM_PATH..' '..stream_path
	stream_process = io.popen(stream_cmd)

	mp.commandv('show-text','Whisper Subtitles: Stream download started')
end


local function whispSubs(media_path, file_length, current_pos, is_stream)

	if running then
		-- Towards the of the file lets just process the time left if smaller than CHUNK_SIZE
		local time_left = file_length - current_pos
		if (time_left < CHUNK_SIZE) then
			CHUNK_SIZE = time_left
		end

		if (time_left > 0) then

			if (createWAV(media_path..'*', current_pos)) then

				if is_stream and not stream_downloaded then
					checkStreamStatus()

					if (isWavLongEnough(current_pos)) then
						current_pos = appendSubs(current_pos)
					else  -- Wait longer for stream
						os.execute('sleep 1')
					end
				else
					current_pos = appendSubs(current_pos)
				end
			end

			-- Callback
			mp.add_timeout(0.1, function() whispSubs(media_path, file_length, current_pos, is_stream) end)
		else
			if not is_stream then
				saveSubs(media_path)
				cleanup()
			else
				mp.commandv('show-text', 'Whisper Subtitles: Subtitles finished processing', 3000)
			end
		end
	end
end



local function run()

	--init vars
	local media_path = mp.get_property('path')
	media_path = '"'..media_path..'"' -- fix spaces
	local file_length = mp.get_property_number('duration/full') * 1000
	local current_pos = INIT_POS
	stream_process = nil

	-- In the rare case that the media is less than CHUNK_SIZE
	local time_left = file_length - current_pos
	if (time_left < CHUNK_SIZE) then
		CHUNK_SIZE = time_left
	end

	-- Determine if media is a stream
	if mp.get_property('demuxer-via-network') == 'yes' then

		stream_downloaded = false
		startStream(media_path)

		-- Wait for stream to get long enough
		local wav_created = false
		for i=0,STREAM_TIMEOUT,1 do
			wav_created = createWAV(TMP_STREAM_PATH..'*', current_pos)

			if wav_created then
				if (isWavLongEnough(current_pos)) then break end
			end
			os.execute('sleep 1')
		end
		if not wav_created or not (isWavLongEnough(current_pos)) then
			mp.commandv('show-text', 'Whisper Subtitles: Timed out waiting for stream for '..STREAM_TIMEOUT..' seconds', 5000)
			stop()
			return
		end

		current_pos = createSubs(current_pos)

		mp.add_timeout(0.1, function() whispSubs(TMP_STREAM_PATH, file_length, current_pos, true) end)
	else
		createWAV(media_path, current_pos)
		current_pos = createSubs(current_pos)
		mp.add_timeout(0.1, function() whispSubs(media_path, file_length, current_pos, false) end)
	end
end

local function toggle()

	if running then
		running = false
		mp.commandv('show-text', 'Whisper subtitles: no')
		mp.unregister_event("start-file", run)
		mp.unregister_event('end-file', stop)

		stop()

	else
		running = true
		mp.commandv('show-text', 'Whisper subtitles: yes')
		mp.register_event("start-file", run)
		mp.register_event('end-file', stop)

		run()
	end

end

mp.add_key_binding('ctrl+.', 'whisper_subs', toggle)
