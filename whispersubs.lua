local TMP_WAV_PATH = "/tmp/mpv_whisper_tmp_wav.wav"
local TMP_SUB_PATH = "/tmp/mpv_whisper_tmp_sub" -- without file ext "srt"
local TMP_STREAM_PATH = "/tmp/mpv_whisper_tmp_stream"
local WHISPER_CMD = "whisper.cpp-medium --threads 10 --max-len 60 --language en"
local CHUNK_SIZE = 15 * 1000 -- the amount of subs to process at a time in ms
local WAV_CHUNK_SIZE = CHUNK_SIZE + 1000
local INIT_POS = 0 -- starting position to start creating subs in ms
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

	mp.commandv('show-text', 'Subtitles finished processing: saving to'..sub_path, 3000)

	os.execute('cp '..TMP_SUB_PATH..'.srt '..sub_path, 'r')
end


local function appendSubs(current_pos)

	os.execute(WHISPER_CMD..' --output-srt -d '..CHUNK_SIZE..' -f '..TMP_WAV_PATH..' -of '..TMP_SUB_PATH..'_append', 'r')

	-- offset srt timings to current_pos
	os.execute('ffmpeg -hide_banner -loglevel error -itsoffset '..current_pos..'ms -i '..TMP_SUB_PATH..'_append.srt'..' -c copy -y '..TMP_SUB_PATH..'_append_offset.srt', 'r')

	-- Append subs manually because whisper won't
	os.execute('cat '..TMP_SUB_PATH..'_append_offset.srt'..' >> '..TMP_SUB_PATH..'.srt', 'r')

	if SHOW_PROGRESS then
		mp.commandv('show-text','Whisper Subtitles: '..formatProgress(current_pos))
	end

	mp.command('sub-reload')

	return current_pos + CHUNK_SIZE
end



local function createSubs(current_pos)

	mp.commandv('show-text','Whisper Subtitles: Generating initial subtitles')

	local handle = io.popen(WHISPER_CMD..' --output-srt -d '..CHUNK_SIZE..' -f '..TMP_WAV_PATH..' -of '..TMP_SUB_PATH, 'r')
	local output = handle:read('*all')
	handle:close()

	mp.commandv('sub-add', TMP_SUB_PATH..'.srt')

	return current_pos + CHUNK_SIZE
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

	stream_cmd = 'yt-dlp --no-part -r 2M -x -o '..TMP_STREAM_PATH..' '..stream_path
	stream_process = io.popen(stream_cmd)

	mp.commandv('show-text','Whisper Subtitles: Stream download started')
end


local function whispSubs(media_path, file_length, current_pos, is_stream)

	if running then
		if (current_pos < file_length) then

			if not stream_downloaded or not is_stream then
				if (createWAV(media_path, current_pos)) then
					current_pos = appendSubs(current_pos)
				end
			else -- After the stream is downloaded we won't know the file ext so we add a * wildcard'
				if (createWAV(media_path..'*', current_pos)) then
					current_pos = appendSubs(current_pos)
				end
			end


			if is_stream then
				checkStreamStatus()
			end
			--Callback
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
	local file_length = mp.get_property_number('playtime-remaining') * 1000
	local current_pos = INIT_POS
	stream_process = nil

	-- Determine if media is a stream
	if mp.get_property('demuxer-via-network') == 'yes' then

		stream_downloaded = false
		startStream(media_path)

		-- wait 15 secs for first wav to be created
		local wav_created = false
		local stream_paths = {TMP_STREAM_PATH, TMP_STREAM_PATH..'*'}
		for i=0,15,1 do
			wav_created = createWAV(stream_paths[(i%2)+1], current_pos)

			if wav_created then break end
			os.execute('sleep 1')
		end
		if not wav_created then
			mp.commandv('show-text', 'Whisper Subtitles: Failed to create a wave file from stream in 15 seconds', 5000)
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
