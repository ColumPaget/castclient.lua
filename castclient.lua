require("stream")
require("strutil")
require("dataparser")
require("process")
require("filesys")
require("terminal")
require("rawdata")
require("time")
require("hash")
require("net")

--casts_dir is our main 'working dir' where we store all the config files and downloadable items like rss feeds and media files

paths={}
paths.casts_dir=process.getenv("HOME").."/.castclient/"
paths.feeds_lst=paths.casts_dir.."/feeds.lst"
paths.update_lck=paths.casts_dir.."/update.lck"
paths.settings_conf=paths.casts_dir.."/settings.conf"

settings={}

players={}
player_state_idle=0
player_state_play=1
player_state_pause=2
player_state_stopped=3
player_state=player_state_idle

player=nil
play_item=nil
play_start=0
play_index=-1


feeds={}
feeds_last_update=0
feeds_update_pid=0
feeds_show_urls=false
feeds_screen_pos=nil

screen_feeds=0
screen_playlist=1
screen_settings=2
curr_screen=screen_feeds
screen_reload_needed=true
screen_refresh_needed=false


downloads={}
downloader_pid=0
curr_chan=""

control_strings={}

now_playing={}

feeds_update_proc=nil

--returns a file-extension type short name for a content type
function ContentTypeToShortName(content_type)
local extn=""

if strutil.strlen(content_type) > 0
then
	if content_type=="audio/mp3" then extn="mp3"
	elseif content_type=="audio/mp4" then extn="m4a"
	elseif content_type=="audio/mpeg" then extn="mp3"
	elseif content_type=="audio/ogg" then extn="ogg"
	elseif content_type=="application/ogg" then extn="ogg"
	elseif content_type=="audio/aac" then extn="aac"
	elseif content_type=="audio/aacp" then extn="aac"
	end
end

return extn
end



function MediaStreamOpen(items)
local str, item

if items==nil then return nil end
for str,item in pairs(items)
do
	if item.url ~= nil
	then
	S=stream.STREAM(item.url, "r Icy-Metadata=1")
	if S ~= nil then return S end
	end
end

return nil
end



function IcecastReadMetadata(icecast)
local toks, str, size, bytes, val
local bytes_read=0

size=icecast.stream:readbyte() * 16
icecast.bytes_read=0
if size > 0
then
	bytes=rawdata.RAWDATA("", size)
	while bytes_read < size
	do
		val=bytes:readat(icecast.stream, bytes_read, size-bytes_read)
		if val > 0 then bytes_read = bytes_read + val end
	end

	toks=strutil.TOKENIZER(bytes:copystr(), ";")
	str=toks:next()
	while str ~= nil
	do
		if string.sub(str, 1, 12) == "StreamTitle="
		then
			str=strutil.stripQuotes(string.sub(str, 13))
			Out:writeln("NowPlaying:"..icecast.stream_type..":"..str.."\n")
			Out:flush()
		end
		str=toks:next()
	end

end

end


function IcecastCopyBytes(icecast)
local val, player_s
local result=0

player_s=icecast.player:get_stream()
if icecast.stream ~= nil
then
if icecast.bytes_read < icecast.blocksize 
then
	if player_s:out_space() > icecast.pushsize
	then
		val=icecast.blocksize - icecast.bytes_read
		if val > icecast.pushsize then val=icecast.pushsize end
		result=icecast.bytes:read(icecast.stream, val)
		if result < 1 then return -1 end
		if result > 0 then icecast.bytes_read=icecast.bytes_read + result end
		icecast.bytes:write(player_s)
	end
		player_s:flush()
else 	
	if icecast.metadata==true then IcecastReadMetadata(icecast) end
	Out:writeln("Cache: "..  player_s:out_queued() .. ":".. player_s:bufsize().."\n")
	Out:flush()
	process.collect()
	icecast.bytes_read=0
end
end

return result
end


function IcecastOpen(config_url)
local S, str, url=nil, items, item

S=stream.STREAM(config_url, "r Icy-Metadata=1")
if S ~= nil
then
	ct=S:getvalue("HTTP:content-type")

	if ct=="audio/aacp" then return(S) end
	if ct=="audio/mpeg" then return(S) end
	if ct=="application/ogg" then return(S) end
	if ct=="audio/ogg" then return(S) end

	if ct=="audio/x-scpls" then items=PLSPlaylistRead(S) end
	if ct=="audio/x-mpegurl" then items=M3UPlaylistRead(S) end
	if ct=="application/xspf+xml" then items=XSPFPlaylistRead(S) end
	if ct=="application/xspf" then items=XSPFPlaylistRead(S) end

	S:close()

	if items ~= nil then return(MediaStreamOpen(items)) end
end

return nil
end


function IcecastPlayerInit(item)
local player_info, player_s, S
local icecast={}

	S=IcecastOpen(item.url)
	if S==nil then return nil end

	Out=stream.STREAM("-")
	icecast.stream=S
	icecast.pushsize=1024
	icecast.blocksize=tonumber(icecast.stream:getvalue("HTTP:icy-metaint"))
	if icecast.blocksize ~= nil 
	then
		icecast.metadata=true
	else
		icecast.metadata=false
		icecast.blocksize=4096 * 10
	end

	icecast.bytes=rawdata.RAWDATA("", icecast.blocksize)
	icecast.bytes_read=0

	icecast.content_type=icecast.stream:getvalue("HTTP:content-type")
	icecast.stream_type=ContentTypeToShortName(icecast.content_type)

	player_info=SelectPlayer(item.url, icecast.content_type) 
	icecast.player=process.PROCESS( SetupPlayerCommand(player_info) .. " -", "noshell outnull")

	if icecast.player ~= nil
	then
	player_s=icecast.player:get_stream()
	player_s:timeout(0)
	player_s:nonblock()
	player_s:bufsize(strutil.fromMetric(settings.stream_cache_size.value))
	player_s:fillto(player_s:bufsize(0) * tonumber(settings.stream_cache_fillto.value) / 100.0)
	end

	return icecast
end

function IcecastLaunchPlayer(item)
local Data, proc
local icecast={}

proc=process.PROCESS("", "newpgroup")
if proc==nil
then
	process.lu_set("HTTP:Debug", "N")

	icecast=IcecastPlayerInit(item)
	if icecast ~= nil
	then
		while IcecastCopyBytes(icecast) > -1
		do
		end
	end
	os.exit(0)
else
	return proc
end

end



function PlayerReadMessage(S)
local str, tok

str=S:readln()
if str ~= nil
then
	str=strutil.trim(str)
	toks=strutil.TOKENIZER(str, ":| - ", "m")
	--if string.sub(str, 1, 11)=="NowPlaying:" 
	tok=toks:next()

	if tok=="NowPlaying"
	then 
	now_playing.stream_type=toks:next()
	now_playing.artist=toks:next()
	now_playing.track=toks:remaining()
	StatusBarDisplay()
	elseif tok=="Cache"
	then
	now_playing.cache_full=tonumber(toks:next())
	now_playing.cache_size=tonumber(toks:next())
	now_playing.cache_percent=now_playing.cache_full * 100 / now_playing.cache_size
	end
end

end



function FeedsUpdateItem(str)
local item

item=FeedsParseItem(str)
existing=feeds[item.url]
if existing ~= nil
then
	if strutil.strlen(existing.title) == 0 or existing.title==existing.url then existing.title=item.title end
	item.updated=item.updated
else
	feeds[item.url]=item
end

end



function FeedsProcessReadMessage(S)
local str

str=S:readln()
if str ~= nil
then
	FeedsUpdateItem(str)
	FeedsSave(feeds)
else
	feeds_update_proc=nil
end
end


-- does more than just get a keypress, this function handles any other streams that 
-- may require servicing, but the main program loop doesn't know about that
function GetKeypress()
local poll, S, result, end_time


poll=stream.POLL_IO()
poll:add(Out:get_stream())
if player ~= nil 
then 
S=player:get_stream()
if S ~= nil then poll:add(player:get_stream())  end
end

if feeds_update_proc ~= nil
then
poll:add(feeds_update_proc:get_stream())
end

if PlaylistProcess() then screen_refresh_needed=true end
end_time=time.centisecs() + 30

while time.centisecs() < end_time
do
	S=poll:select(10)
	if S ~= nil
	then
		if S==Out:get_stream()
		then 
			screen_refresh_needed=true
			return(Out:getc())
		elseif player ~= nil and S==player:get_stream()
		then
			PlayerReadMessage(S)
		elseif feeds_update_proc ~= nil and S==feeds_update_proc:get_stream()
		then
			FeedsProcessReadMessage(S)
		end
	end
end

return(nil)
end



-- strip html out of a string (usually channel/episode descriptions)
function StripHtml(html)
local toks, tok, str

str=""
toks=strutil.TOKENIZER(html, "<|>| ", "ms")
tok=toks:next()
while tok ~= nil
do
	if tok == "<" 
	then
	while tok ~= nil and tok ~= ">" do tok=toks:next() end
	else
		str=str..tok
	end

	tok=toks:next()
end

return(strutil.htmlUnQuote(str))
end



-- display an text area at row 'y' that's 'len' lines long. the text will fill the full width of the page
function TextArea(y, len, text)
local str, line, start, wid

str=string.gsub(text, "\n", " ")
textlen=strutil.strlen(str)
Out:move(0, y)

wid=Out:width() -1
for i=0,len,1
do
start=(i * wid) +1
if start >= textlen
then
line=""
else
line=string.sub(str, start, start+wid) 
end

line=line.. "~>\n"
Out:puts(line)
end

end



function SubstituteVars(str, Vars)
local key, value, retstr

retstr=str
for key,value in pairs(Vars)
do
	value=string.gsub(value, "%%", "%%%%")
	retstr=string.gsub(retstr, "%("..key.."%)", value)
end

return(retstr)
end


function PlayItemSubstituteVars(str, item)
local elapsed
local vars={}

if item ~= nil
then
	vars.title=item.title
	vars.now_playing=item.title
	vars.artist=""
	vars.track=""
	vars.stream_cache=""
	vars.path=item.url
	vars.file=filesys.basename(item.url)
	elapsed=time.secs() - play_start
	vars.elapsed=time.formatsecs("%H:%M:%S", elapsed)
if item.duration ~= nil and item.duration > 0
then
	vars.duration=time.formatsecs("%H:%M:%S", item.duration)
	vars.percent=string.format("%02d", math.floor( (elapsed * 100) / item.duration) )
else 
	vars.duration="unknown"
	vars.percent="??"
end

if item.type == "stream"
then
	vars.now_playing=now_playing.artist.." - "..now_playing.track
	vars.artist=now_playing.artist
	vars.track=now_playing.track
	vars.stream_type=now_playing.stream_type
	if now_playing.cache_percent ~= nil then vars.stream_cache=string.format("%03.1f", now_playing.cache_percent) end
end

vars.queue_curr=string.format("%d", play_index)
vars.queue_size=string.format("%d", #downloads)
end

return (SubstituteVars(str, vars))
end


marquee=0

function XtermTitle(item)
local str, vars, outstr, pos

str="~:music: castclient.lua"

if strutil.strlen(settings.xterm_title.value) > 0 and strutil.strlen(now_playing.artist) > 0
then
str=PlayItemSubstituteVars(settings.xterm_title.value, item) 
end

if strutil.strlen(str) > 0
then
  outstr=string.format("\x1b]2;%s\x07", str)
  Out:puts(outstr)
end

--[[
	str=str .. "     "
	pos=marquee % strutil.strlen(str)
	marquee=marquee+1
	outstr=string.sub(str, pos)..string.sub(str, 1, pos)
  str=string.format("\x1b]3;WM_CLASS=%s\x07", outstr)
  Out:puts(str)
end
end
]]--

end




-- translate feed names from 'front page' urls to 'rss feed' urls. Currently this only applies to bitchute channel pages
function TranslateFeed(input_url)
local bitchute_channel="https://www.bitchute.com/channel/"
local output_url

if string.sub(input_url, 1, strutil.strlen(bitchute_channel))==bitchute_channel
then
	output_url= "https://www.bitchute.com/feeds/rss/channel/" .. string.sub(input_url, strutil.strlen(bitchute_channel))
else
	output_url=input_url
end

return output_url
end



function PlaybackGetCurrItem(downloads, pid)
local i, item

for i,item in ipairs(downloads)
do
	if item.pid==pid 
	then 
		play_index=i
		return item,i 
	end
end

return nil,nil
end


function PlaybackPause()
if player ~= nil and player:pid() > 0
then
	if player_state==player_state_play
	then
		player_state=player_state_pause
		player:pause()
	elseif player_state==player_state_pause
	then
		player_state=player_state_play
		player:continue()
	end
end
end

function PlaybackStop()
if player ~= nil and player:pid() > 0
then
		player_state=state_stopped
		player:continue()
		process.usleep(10000)
		player:stop_pgroup()
end

now_playing.artist=""
now_playing.track=""
end


function SelectPlayerGetFirstMatch(extn)
local i,player

for i,player in ipairs(players)
do
	if player.extn==extn then return player end
end

return nil
end



-- find a player program that can play a given media url/file
function SelectPlayer(media_url, content_type)
local player, extn, str, pos

extn=ContentTypeToShortName(content_type)

if strutil.strlen(extn)==0
then
	pos=string.find(media_url, "?")
	if pos ~= nil then str=string.sub(media_url, 1, pos-1) 
	else str=media_url
	end

	str=filesys.basename(str)
	extn=filesys.extn(str)
	if strutil.strlen(extn) > 0 then extn=string.sub(extn, 2) end
end

if strutil.strlen(extn) > 0 then player=SelectPlayerGetFirstMatch(extn) end
if player==nil then player=SelectPlayerGetFirstMatch("*") end

return player
end



-- find a setting (named by 'key') for a given player program
function LookupPlayerSetting(player_path, key)
local str, setting

str=key..":"..filesys.basename(player_path)
setting=settings[str]
if setting==nil then return nil end

return setting.value 
end



-- setup the command line for a player program, substituting some values (like playback device) from settings
function SetupPlayerCommand(player)
local args, dev, toks, ao_type, ao_id, str

args=player.args

str=LookupPlayerSetting(player.path, "out")
if str ~= nil then args=string.gsub(args, "%(out%)", str) end

str=LookupPlayerSetting(player.path, "dev")
if str ~= nil 
then
toks=strutil.TOKENIZER(str, ":")
ao_type=toks:next()
ao_id=toks:remaining()

args=string.gsub(args, "%(dev%)", str) 
if ao_type ~= nil then args=string.gsub(args, "%(ao_type%)", ao_type) end
if ao_id ~= nil then args=string.gsub(args, "%(ao_id%)", ao_id) end
end

return player.path.." "..args
end



function PLSPlaylistRead(S)
local str, key, toks, val
local items={}

if S==nil then return nil end
str=S:readln()
while str ~= nil
do
	str=strutil.stripTrailingWhitespace(str)
	toks=strutil.TOKENIZER(str, "=")
	key=toks:next()
	if strutil.strlen(key) > 0
	then
	if string.sub(key, 1, 4) == "File" 
	then 
		val=tonumber(string.sub(key,5))
		if items[val]==nil then items[val]={} end
		items[val].url=toks:remaining()
	elseif string.sub(key, 1, 5) == "Title" 
	then
		val=tonumber(string.sub(key,6))
		if items[val]==nil then items[val]={} end
		items[val].title=toks:remaining() 
	end
	end

str=S:readln()
end

S:close()
return items
end




function M3UPlaylistRead(S)
local str, item
local items={}

if S==nil then return nil end
str=S:readln()
while str ~= nil
do
	str=strutil.stripTrailingWhitespace(str)
	if strutil.strlen(str) > 0 
	then 
		if string.sub(str, 1, 1) ~= "#"
		then
			item={}
			item.url=str
			table.insert(items, item)
		end
	end

	str=S:readln()
end

S:close()

return items
end


function XSPFPlaylistRead(S)
local str, item, title, P, I
local items={}

if S==nil then return nil end
P=dataparser.PARSER("xml", S:readdoc())
S:close()

title=P:value("title")
P=P:open("/tracklist")
I=P:next()
while I ~= nil
do
	if I:name()=="track"
	then
	str=I:value("location")
	if strutil.strlen(str) > 0 
	then 
			item={}
			item.title=title
			item.url=str
			table.insert(items, item)
	end
	end

I=P:next()
end


return items
end




function CachedFilePlayer(item)
local player_info, proc, cmd, str, media_path

media_path=CachePath(item.url)
if filesys.exists(media_path) ~= true then media_path=item.url end

--whatever happens update the mtime of the file, 'cos we tried to play it, so we don't want it cleaned up
filesys.touch(media_path)

player_info=SelectPlayer(item.url) 
cmd=SetupPlayerCommand(player_info) .. " "..  media_path

proc=process.PROCESS(cmd, "pty noshell outnull newpgroup")

if proc ~= nil
then
	--if a play command exists, then use it
	str=LookupPlayerSetting(proc:exec_path(), "play")
	if str ~= nil 
	then 
		str=string.gsub(str, "%(url%)", media_path)
		proc:send(str) 
	end
end

return proc
end



function LaunchPlayerProcess(item)
local player

if item.type=="stream" and settings.handle_streams.value==true
then 
	player=IcecastLaunchPlayer(item) 
else
	player=CachedFilePlayer(item) 
end

return(player)
end


-- start playing a playlist item by looking up a player program that can play the file type and launching that
function PlayItem(item)
local pid

PlaybackStop() 
player=LaunchPlayerProcess(item)
if player ~= nil and player:pid() > 0
then
	player_state=player_state_play
	play_item=item
	play_start=time.secs()
	item.pid=player:pid()
	item.played=true
	StatusBarDisplay()
end

end



-- kill the current player program and start playing the previous item in the playlist
function PlaybackPrev()
local i, item, pos

if player ~= nil and player:pid() > 0 
then 
	item,pos=PlaybackGetCurrItem(downloads, player:pid())
	--PlaybackStop() 
end

--lua arrays start at 1, so we set this to 2 and let the next line decrement it
if pos < 2 then pos=2 end
item=downloads[pos-1]
if item ~= nil
then
	item.played=false
	PlayItem(item) 
end

screen_reload_needed=true
end


-- kill the current player program and start playing the next item in the playlist
function PlaybackNext()
local i, item

if player ~= nil and player:pid() > 0 
then 
	item=PlaybackGetCurrItem(downloads, player:pid())
	--PlaybackStop() 
	if item ~= nil then item.played=true end
end

for i,item in ipairs(downloads)
do
	if item.downloaded==true and item.played==false 
	then 
		PlayItem(item) 
		break
	end
end

screen_reload_needed=true
end

-- kill the current player program and start playing the same item from the start
function PlaybackRestart()
local i, item

if player ~= nil and player:pid() > 0 
then 
	item=PlaybackGetCurrItem(downloads, player:pid())
	--PlaybackStop() 
	PlayItem(item) 
end

end




-- lookup a 'rewind' command for the current player program, and if there is one send it to the program
function PlaybackRewind()
local cmd

if player ~= nil and player:pid() > 0 
then 
	cmd=LookupPlayerSetting(player:exec_path(), "rewind")
	if cmd ~= nil then player:send(cmd) end
end

end

-- lookup a 'fast forward' command for the current player program, and if there is one send it to the program
function PlaybackForward()
local cmd

if player ~= nil and player:pid() > 0 
then 	
	cmd=LookupPlayerSetting(player:exec_path(), "forward")
	if cmd ~= nil then player:send(cmd) end
end

end



-- find item in a list of items by it's url. Depending on the list the items could be RSS feeds or podcast episodes/media files
function FindItemByURL(items, url)
local i, item

if items ~= nil
then
	for i,item in ipairs(items)
	do
		if item ~= nil and item.url==url then return item,i end
	end
end

return nil
end


-- generate a unique file path to cache a downloadable item (RSS feed or media file) under
function CachePath(url)
local str, urlhash, fname, toks

toks=strutil.TOKENIZER(url, "?")
fname=filesys.basename(toks:next())

if strutil.strlen(fname) ==0 then fname="feed" end

urlhash=hash.hashstr(url, "md5", "hex");

str=paths.casts_dir .. urlhash .. "-".. fname

return str
end


function ContentTypeIsStream(content_type)

if content_type=="audio/x-scpls" then return true end
if content_type=="audio/x-mpegurl" then return true end
if content_type=="application/xspf+xml" then return true end
if content_type=="application/xspf" then return true end
if content_type=="audio/aacp" then return true end
if content_type=="audio/ogg" then return true end
if content_type=="audio/mpeg" then return true end
if content_type=="application/ogg" then return true end

return false
end

function URLGetType(url)
local S, ct, ftype="rss"

S=stream.STREAM(url)
if S ~= nil
then
ct=S:getvalue("HTTP:content-type")
if ContentTypeIsStream(ct) == true then ftype="stream" end
S:close()
end

return ftype
end

-- this function checks if a url is in the cache. If not, or if it's older than a certain 
-- amount, it downloads the url to the cache. If the cache dir is not writable it returns 
-- the original url, otherwise it returns a path to the downloaded file
function FeedFromCache(url)
local path, done_path, ftype
local cache_age=0

path=CachePath(url)
done_path=path..".rss"

if filesys.exists(done_path) == true 
then 
	cache_age=filesys.mtime(done_path) 
else
	--file does not exist in cache, we'd better check what it is!
	ftype=URLGetType(url)
end

if ftype ~= "stream"
then
if time.secs() - cache_age > settings.feed_cache_time.seconds
then
	filesys.copy(url, path)
	filesys.rename(path, done_path)
end

if filesys.exists(done_path) == true then return done_path end
end

return url
end



function FeedsParseItem(input)
local toks, item, str

	toks=strutil.TOKENIZER(input, "\\S", "Q")

	item={}
	item.title=""
	item.type=""
	item.updated=0
	item.url=strutil.stripTrailingWhitespace(toks:next())

	str=toks:next()
	while str ~= nil
	do
		if string.sub(str, 1, 8) == "updated=" then item.updated=tonumber(string.sub(str, 9)) end
		if string.sub(str, 1, 6) == "title=" then item.title=strutil.htmlUnQuote(strutil.unQuote(string.sub(str, 7))) end
		if str == "stream" then item.type="stream" end
	str=toks:next()
	end

	if strutil.strlen(item.title)==0 then item.title=item.url end

return item
end



function FeedsSortByTime(i1, i2)
if i1.type=="stream"
then
	if i2.type ~= "stream" then return true end
	if i1.title < i2.title then return true end
	return false
end
if i2.type == "stream" then return false end

return i1.updated > i2.updated
end


-- check if it's time to update the feeds.lst file by connecting to RSS feed urls and checking if they've changed
function FeedsRequireUpdate()
local mtime

if #feeds < 1 then return true end

now=time.secs()
mtime=filesys.mtime(paths.feeds_lst)
if (now - mtime ) > settings.feed_update_time.seconds then return true end

return false
end





-- load list of available feeds from the feeds.lst file. If 'add_method' is set to 'by url' then put
-- them in a table using the url as a key. Otherwise put them in the table with an index as the key
-- using 'table.insert'
function FeedsGetList(path, method)
local S, str, mtime, item

now=time.secs()
mtime=filesys.mtime(path)
--if feeds exists, and the feeds file is older than it, then use cached feeds
if feeds == nil or mtime > feeds_last_update or #feeds == 0 
then 
feeds_last_update=now

--load new feeds
feeds={}
S=stream.STREAM(path, "r")
if S ~= nil
then
	str=S:readln()
	while str ~= nil
	do
		if strutil.strlen(str) > 0 
		then 
			if method=="by url" or method=="new"
			then
				item=FeedsParseItem(str)
				feeds[item.url]=item
			else
			table.insert(feeds, FeedsParseItem(str)) 
			end
		end
		str=S:readln()
	end
	S:close()
end
end

return feeds,true
end


-- formats a feed to be displayed on the main feed screen, coloring it to indicate recently updated feeds
function FeedOrStreamTitle(Screen, item)
local str, daysecs, diff, title
local timecolor=""


if strutil.strlen(item.title) > 0 and feeds_show_urls ~= true 
then
	title=item.title
else
	title=item.url
end

if item.type=="stream" then return("~e~wstream~0       " .. title) end


diff=time.secs() - item.updated
daysecs=3600 * 24
if diff < daysecs then timecolor="~r"
elseif diff < (daysecs * 3) then timecolor="~e~y"
end

if timecolor ~= ""
then
str=time.formatsecs(timecolor.."%Y/%m/%d~0~e  ", item.updated) 
else
str=time.formatsecs("%Y/%m/%d  ", item.updated) 
end

str=str .. " " .. title .. "~0"

return str
end



-- dates in feeds are a bit of a mess. In general no-one in tech seems able to agree on a date format!
function FeedParseDate(parser)
local toks, str, when

		str=parser:value("pubDate")
		when=time.tosecs("%a, %d %b %Y %H:%M:%S", str)
		
		--probable date parse failure. Could the day name be missing?
		if when < 1
		then
		when=time.tosecs("%d %b %Y %H:%M:%S", str)
		end

		--probable date parse failure. Could be that the day name is something unrecognized
		if when < 1
		then
			toks=strutil.TOKENIZER(str, ",| ", "m")
			str=toks:next()
			str=toks:remaining()
			str=strutil.stripLeadingWhitespace(str)			
			when=time.tosecs("%d %b %Y %H:%M:%S", str)
		end

if when < 0 then when=0 end
return when
end


function RSSFeedRead(S)
local str, P, I
local latest=0
local chan={}
local items={}

chan.title=""
chan.description=""
chan.updated=0

str=S:readdoc()

P=dataparser.PARSER("rss", str)
S:close()

if P ~= nil
then
I=P:next()
while I ~= nil
do

	if I:name() == "title"
	then
		chan.title=I:value()
	elseif I:name()=="description"
	then
		chan.description=strutil.htmlUnQuote(I:value())
--[[
	elseif I:name()=="lastBuildDate" or I:name()=="pubDate"
	then
		chan.updated=time.tosecs("%a, %d %b %Y %H:%M:%S", I:value())
]]--
	elseif string.sub(I:name(), 1, 5)=="item:" 
	then 
		item={}
		item.link=I:value("link")
		item.url=I:value("enclosure_url")
		if strutil.strlen(item.url) == 0 then item.url=I:value("link") end
		item.size=I:value("enclosure_length")
		item.title=strutil.htmlUnQuote(strutil.htmlUnQuote(strutil.unQuote(I:value("title"))))
		item.description=string.gsub(StripHtml(I:value("description")), "\r\n", "\n")
		item.when=time.tosecs("%a, %d %b %Y %H:%M:%S", I:value("pubDate"))
		item.when=FeedParseDate(I)
		str=I:value("itunes:duration")
		if str ~= nil 
		then 
			item.duration=time.tosecs("%s", str) 
		end
		if latest < item.when then latest=item.when end
		table.insert(items, item)
	end
	I=P:next()
end
end

if chan.updated==0 then chan.updated=latest end

return chan,items
end



-- get a feed RSS file from cache, or download if cache is too old
function FeedGet(iurl)
local S, str, ct, toks, url, chan, items

url=FeedFromCache(iurl)

S=stream.STREAM(url, "r" .. " timeout=" .. settings.network_timeout.value)
if S ~= nil
then
	chan,items=RSSFeedRead(S)
	S:close()
end

return chan,items
end




--this function gets the playlist file for streams that use m3u, pls or other 
--'playlist' files to describe the stream
function StreamGetPlaylistDetails(S)
local str, toks, ct, items
local chan={}


chan.type="stream"
chan.title=""
chan.description=""
chan.updated=0

str=S:getvalue("HTTP:content-type")
toks=strutil.TOKENIZER(str, ";")
ct=toks:next()

if ct=="audio/x-scpls" then items=PLSPlaylistRead(S) end
if ct=="audio/x-mpegurl" then items=M3UPlaylistRead(S) end
if ct=="application/xspf+xml" then items=XSPFPlaylistRead(S) end
if ct=="application/xspf" then items=XSPFPlaylistRead(S) end

if items ~= nil and items[1] ~= nil
then
	chan.title=items[1].title
end

return chan,nil
end




function StreamGet(url)
local str, toks, ct, chan, items

S=stream.STREAM(url, "r" .. " timeout=" .. settings.network_timeout.value)
if S ~= nil
then
		str=S:getvalue("HTTP:content-type")
		if str ~= nil
		then
		toks=strutil.TOKENIZER(str, ";")
		ct=toks:next()

		if ContentTypeIsStream(ct)
		then
			chan,items=StreamGetPlaylistDetails(S)
		elseif ct=="text/xml" or ct=="application/xml" or ct=="application/rss+xml" then chan,items=RSSFeedRead(S)
		end

		end
	S:close()
end

return chan,items
end



function FeedItemSend(S, item)
local str

str=string.format("%s %s updated=%d ", item.url, item.type,  item.updated)
if strutil.strlen(item.title) > 0 then str=str.. " title=" ..strutil.quoteChars(item.title, "' 	") end
S:writeln(str.."\n")
end



-- this is called by the feeds update process and writes out the list of feeds to a new feeds.lst file
function FeedsSave(feed_list)
local i, item, S, str

if #feed_list > 0
then
S=stream.STREAM(paths.feeds_lst.."+", "w")
if S ~= nil
then
	S:waitlock()
	for i,item in ipairs(feed_list) 
	do
		FeedItemSend(S, item)
	end

	filesys.copy(paths.feeds_lst, paths.feeds_lst.."-")
	filesys.rename(paths.feeds_lst.."+", paths.feeds_lst)
	S:close()
end
end

end




--feeds are added to a feeds.new file to prevent two processes trying to write to feeds.lst file at the same time. The feeds update process will then pull in any items in feeds.new when it's free to do so
function FeedsAdd(url, title)
local S, str
local item={}

item.type=""
item.url=TranslateFeed(url)
item.updated=0
item.title=title
feeds[item.url]=item

FeedsSave(feeds)
end


-- dialog that prompts the user to enter a feed url to be added to the feeds list
function FeedsAddDialog()
local url

Out:clear()
Out:move(0,Out:length()-1)
Out:puts("~B~w~eAdd Feed~>~0")

Out:move(0,0)
Out:puts("~B~w~eAdd Feed~>~0\n\n")

Out:puts("Press Escape twice to cancel adding feed\n\n")

url=Out:prompt("~eEnter URL:~0 ")

if strutil.strlen(url) > 0 then FeedsUpdateItem(url) end

FeedsSave(feeds)
--clear output so next screen isn't messed up
Out:clear()
end



-- this function is called within a forked-off subprocess, hence the os.exit() at the end of it
-- it's job is to download and import feed urls to see if any new items have appeared
function FeedsUpdateSubprocess()
local feed_list, i, feed, chan, items, last_save
local Out

	Out=stream.STREAM("-", "rw")
	feed_list=FeedsGetList(paths.feeds_lst, "new")
	last_save=time.secs()

	for i,feed in ipairs(feed_list)
	do
		if strutil.strlen(feed.url) > 0 
		then
			if feed.type == "stream"
			then
				chan,items=StreamGet(feed.url)
			else
				chan,items=FeedGet(feed.url)
			end

			if chan ~= nil
			then
				feed.type=chan.type
	--			if strutil.strlen(feed.title) == 0 or feed.title == feed.url then feed.title=chan.title end
				feed.description=chan.description
				feed.updated=chan.updated
				if items~=nil then feed.size=#items end
			end
		end

		-- collect any child processes
		pid=process.collect()
		while pid > 1
		do
		pid=process.collect()
		end

		FeedItemSend(Out, feed)
		Out:flush()
	end

	os.exit(1)
end


-- this function updates the feeds.lst status file in the .castclient directory
function FeedsUpdate()
local lockfile


lockfile=stream.STREAM(paths.update_lck, "w")
if lockfile 
then
	if lockfile:lock()
	then
		feeds_update_proc=process.PROCESS("", "newpgroup")

		--if proc==nil after a form, then we're in the child process
			if feeds_update_proc==nil
			then 
				lockfile:writeln(string.format("%d\n", process.getpid()))
				FeedsUpdateSubprocess()
				os.exit(0)
			end

	end
	lockfile:close()
end

return proc
end


-- find currently downloading item
function DownloadFindCurr(downloads)
local i, item

for i,item in ipairs(downloads)
do
if item.pid==downloader_pid then return item end

end

return nil
end


-- find next item needing download, not related to playback
function DownloadFindNext(downloads, pid)
local i, item

for i,item in ipairs(downloads)
do
	if item.pid ~= 0 and item.pid == pid 
	then 
		item.downloaded=true 
		item.pid=0
	end

	if item.downloaded==false then return item end
end

return nil
end


-- do any reformatting that's needed to get the real download URL of a media item. This currently only applies to bitchute, where we have to do a dance to find the 'real' url of a media file 
function DownloadPreProcess(item)
local bitchute_url="https://www.bitchute.com/embed/"
local toks, tok, str

if string.sub(item.link, 1, strutil.strlen(bitchute_url))==bitchute_url
then
	S=stream.STREAM(item.link, "r")
	if S ~= nil then str=S:readdoc() end
	S:close()

	toks=strutil.TOKENIZER(str, "<|>|\\S", "ms")
	tok=toks:next()
	while tok ~= nil
	do
		if tok=="<" and toks:next() == "source"
		then
			while tok ~= ">"
			do
				if string.sub(tok, 1, 4) == "src=" 
				then 
					item.url=strutil.stripQuotes(string.sub(tok, 5))
				end
				tok=toks:next()
			end
		end

		tok=toks:next()
	end
end

end


-- clear old items out of the download cache
function DownloadsCleanup(now)
local str, files

files=filesys.GLOB(paths.casts_dir.."/*")
str=files:next()
while str ~= nil
do
	if now - tonumber(filesys.mtime(str)) > settings.cache_media_time.seconds
	then 
		if filesys.basename(str) ~= "feeds.lst" then filesys.unlink(str) end
	end

str=files:next()
end

end


-- go through the playlist checking if items need downloading or playing until all have been downloaded and played
function PlaylistProcess()
local pid=0
local next_item, now
local retval=false

now=time.secs()
 
if feeds_update_pid==0 and FeedsRequireUpdate() == true
then
 FeedsUpdate()
end

DownloadsCleanup(now)

pid=process.collect()

if pid ~= 0
then
	retval=true
	if pid==downloader_pid then downloader_pid=0 end
	if pid==feeds_update_pid then feeds_update_pid=0 end
	if player ~= nil and pid==player:pid() 
	then 
		player=nil
		player_state=player_state_idle
		play_item=nil
		StatusBarDisplay()
	end
end

	
if downloader_pid==0
then
		next_item=DownloadFindNext(downloads, pid)
	
		if next_item ~= nil
		then
			downloader_pid=process.xfork("innull outnull")
			if downloader_pid==0
			then
				filesys.copy(next_item.url, CachePath(next_item.url));
				os.exit(0);
			end
		
			next_item.pid=downloader_pid
--			screen_reload_needed=true
		end
end

if player == nil or player:pid()==0 then PlaybackNext() end

return retval
end


-- add an item to the playlist
function PlaylistAdd(item)
local path

item.pid=0
item.downloaded=false
item.played=false

DownloadPreProcess(item)
if filesys.exists(CachePath(item.url)) == true then item.downloaded=true end

table.insert(downloads, item)

PlaylistProcess()
screen_reload_needed=true
end


-- get the position in the playlist of the currently playing item
function NowPlayingItemNo()

for i,item in ipairs(downloads)
do
	if player ~= nil and item.pid == player:pid() then return i end
end

return 0
end



function HelpDisplay()
	Out:clear()
	Out:move(0,1)
	Out:puts("~bKey Bindings~0\n");
	Out:puts("    ?            This help\n")
	Out:puts("    " .. settings.exit_key.value .. "     to quit application\n")
	Out:puts("    escape       Press escape twice to exit a menu\n")
	Out:puts("    up arrow     Move menu selection up\n")
	Out:puts("    down arrow   Move menu selection down\n")
	Out:puts("    left arrow   Switch between top-level menus\n")
	Out:puts("    right arrow  Switch between top-level menus\n")
	Out:puts("    enter        Activate selected menu item\n")
	Out:puts("    delete       Delete feed on feeds screen, or item on playlist screen\n")
	Out:puts("    a            Add a new feed\n")
	Out:puts("    c            Clear playlist (only available on playlist screen)\n")
	Out:puts("    s            Stop playback\n")
	Out:puts("    home         Restart playback from beginning\n")
	Out:puts("    end          Stop playback\n")
	Out:puts("    space        Pause current playback\n")
	Out:puts("    shift-left   Rewind current playback\n")
	Out:puts("    shift-right  Fast-forward current playback\n")
	Out:puts("    alt-left     Rewind current playback\n")
	Out:puts("    alt-right    Fast-forward current playback\n")
	Out:puts("    .            Rewind current playback\n")
	Out:puts("    ,            Fast-forward current playback\n")

	Out:puts("    ctrl-left    Skip to previous playlist item\n")
	Out:puts("    ctrl-right   Skip to next playlist item\n")
	
	Out:puts("    u            toggle between names/titles and urls on feeds screen\n")
	Out:puts("    n            change title/name of selected item on feeds screen\n")

	Out:puts("\n")
	Out:puts("~ePRESS ANY KEY TO CLOSE THIS SCREEN\n")

	Out:flush()
	ch=GetKeypress()
	while strutil.strlen(ch) ==0
	do
		ch=GetKeypress()
	end
	
	Out:clear()
end


-- draw the status bar at the bottom of the screen
function StatusBarDisplay()
local str, item

str="~C"
str=str..string.format("Playlist: % 4d items     ", #downloads)

if player_state==player_state_play and play_item ~= nil
then
	if play_item.type=="stream" 
	then 
		str=PlayItemSubstituteVars("~C~w~eSTREAM: ~b(stream_type)~w cache: (stream_cache)% ~y~e(title)~m: (artist)~C~w: (track)", play_item)
	else
		str=PlayItemSubstituteVars("~C~wPLAYING: (queue_curr)/(queue_size) (percent) (elapsed)/(duration) (title)", play_item)
	end
elseif player_state==player_state_pause
then
	str=str.."~rPAUSED: "
elseif downloader_pid ~= 0
then
	item=DownloadFindCurr(downloads)
	str=str.."~wdownloading: "..item.title
else
	str=str.."~nidle"
end


if string.len(str) > Out:width() then str=string.sub(str, 1, Out:width()-1) end

str=str.."~>~0"

Out:move(0, Out:length()-1)
XtermTitle(play_item)
Out:puts(str)


end



-- draw the top bar that allows selecting between the top-level screens
function DrawMenuSelection()
local str

Out:move(0,0)
if curr_screen == screen_feeds
then
	str="  ~e<feeds>~0    playlist     settings "
elseif curr_screen == screen_playlist
then
	str="   feeds    ~e<playlist>~0    settings "
else
	str="   feeds     playlist    ~e<settings>~0"
end

str=str .. "    press '?' to see help menu"
Out:puts(str)
end



function ScreenRefresh(Screen)

DrawMenuSelection()

if Screen.update ~= nil then Screen:update() end
if Screen.draw ~= nil then Screen:draw() end

StatusBarDisplay()
screen_refresh_needed=false
end


-- process the current screen. This loops until a keypress or other event needs handling
function ProcessScreen(Screen)
local ch, str=nil

if process.sigwatch ~= nil then process.sigwatch(28) end
Out:cork()
ScreenRefresh(Screen)
Out:flush() --got to flush this initial screen refresh. After this it will be done in the loop below

ch=GetKeypress()
while str==nil
do

	if ch ~= nil and ch ~= ""
	then

	if ch=="ESC" or ch=="BACKSPACE" or ch==settings.exit_key.value
	then 
		--clear output so next screen isn't messed up
		Out:clear()
		return ch 
	elseif ch==" "
	then
		PlaybackPause()
	elseif ch=="?" 
	then
		HelpDisplay()
		ScreenRefresh(Screen)
	elseif ch=="a"
	then
		FeedsAddDialog()
		screen_reload_needed=true
	elseif ch=="HOME" then PlaybackRestart()
	elseif ch=="END" or ch=="s" then PlaybackStop()
	elseif ch=="LEFT"
	then
		Out:clear()
		if curr_screen > screen_feeds then curr_screen=curr_screen - 1 end
		str=""
		break
	elseif ch=="RIGHT"
	then
		Out:clear()
		if curr_screen < screen_settings then curr_screen=curr_screen + 1 end
		str=""
		break
	elseif ch=="CTRL_LEFT"
	then
		PlaybackPrev()
	elseif ch=="CTRL_RIGHT"
	then
		PlaybackNext()
	elseif ch=="SHIFT_LEFT" or ch=="ALT_LEFT" or ch==","
	then
		PlaybackRewind()
	elseif ch=="SHIFT_RIGHT" or ch=="ALT_RIGHT" or ch=="."
	then
		PlaybackForward()
	else
		if strutil.strlen(ch) > 0
		then
			if Screen.on_key ~= nil 
			then 
				str=Screen.on_key(Screen, ch) 
				else
				str=Screen.menu:onkey(ch)
			end

			if strutil.strlen(str) > 0 then break end
			Screen.menu:draw()
		end
	end

	end

	StatusBarDisplay()
	Out:flush()

	if process.sigcheck ~= nil and process.sigcheck(28) == true
	then
		screen_reload_needed=true
		Out:clear()
		return ""
	end 

	if screen_refresh_needed==true then ScreenRefresh(Screen) end
	ch=GetKeypress()
end

return str
end


-- this doesn't touch any items in the menu, but it does update the description text below the menu
-- as the user moves from episode to episode
function EpisodesScreenUpdate(Screen)
local str, item

if curr_chan ~= nil
then
Out:move(0, 0)
str=string.format("~B~y   ~e%s~0~B~w  %d items~>~0\n", curr_chan.title, #Screen.items)
Out:puts(str);
end

str=Screen.menu:curr()
if str ~=nil
then
	item=FindItemByURL(Screen.items, str)
	if item ~= nil then TextArea(Out:length() -5, 3, item.description) end
end

Screen.menu:draw()
end


-- if a feed is selected on the feed screen, then this screen is displayed showing the episodes/playable items
function EpisodesMenu(url, feeds)
local items, item, Menu, i, toks, str, choice
local Screen={}

Out:clear()
curr_chan,items=FeedGet(url)
Screen.menu=terminal.TERMMENU(Out, 2, 3, Out:width()-4, Out:length() - 10)
Screen.menu:config("~C~n", "~B~y")
Screen.items=items
Screen.draw=EpisodesScreenUpdate


if items ~= nil
then
for i,item in ipairs(items)
do
	str=time.formatsecs("%Y/%m/%d", item.when)  .. "  ~w".. item.title .."~0"
	-- if using a version of libuseful that has a width setter, then we can be smarter about what we display
	if Screen.menu.width ~= nil
	then
	if strutil.strlen(str) < (Screen.menu:width() - 24) 
	then 
		str=str.. "    " .. item.description 
		str=string.sub(str, 1, Screen.menu:width()-4)
		str=string.gsub(str, "\n", " ")
	end
	end
	Screen.menu:add(str, item.url)
end
end

while true
do
	choice=ProcessScreen(Screen)
	if choice=="ESC" then break end

	item=FindItemByURL(items, choice)
	if item ~= nil then PlaylistAdd(item) end
end

screen_reload_needed=true
end


function FeedsScreenOnSelect(Screen, url)
local item, feeds

feeds=Screen.items
item=FindItemByURL(feeds, url)
if item ~= nil
then
	if item.type=="stream" then PlayItem(item)
	else 
		EpisodesMenu(url, feeds)
	end
end

end





function FeedsScreenUpdate(Screen)
local new_items, i, item, new_item, str
local updated=false

new_items,updated=FeedsGetList(paths.feeds_lst)

if updated==true 
then 
for i,item in ipairs(Screen.items) 
do 
  new_item=FindItemByURL(new_items, item.url) 
  if new_item ~= nil and new_item.updated > item.updated 
  then 
    Screen.items[i]=new_item 
    Screen.menu:update(FeedOrStreamTitle(Screen, new_item), new_item.url) 
  end 
end


screen_reload_needed=true
if updated == true then Screen.menu:draw() end
end

end


function FeedsScreenDraw(Screen)

if #Screen.items > 0
then
	Screen.menu:draw()
else
	Out:move(2, 2)
	Out:puts("~eNo feeds configured. Press 'a' to add one~0\n")
end
end



function FeedEditName(url, feeds_list)
local str, feed

feed=FindItemByURL(feeds_list, url)

Out:clear()
Out:move(0,Out:length()-1)
Out:puts("~B~w~eEdit Feed Name: "..url.. "~>~0")

Out:move(0,0)
Out:puts("~B~w~eAdd Feed Name: "..url .. "~>~0\n\n")

Out:puts("Press Escape twice to cancel editing feed\n\n")

str=Out:prompt("~eEnter New Name:~0 ")

if strutil.strlen(str) > 0 
then 
	feed.title=str
	FeedsSave(feeds)
end

--clear output so next screen isn't messed up
Out:clear()
end





function FeedsScreenOnKey(Screen, key)
local url, str, item, i

str=""
if key=="DELETE"
then
	url=Screen.menu:curr()
	item,i=FindItemByURL(Screen.items, url)
	if item ~= nil 
	then 
		table.remove(Screen.items, i) 
		FeedsSave(Screen.items)
		screen_reload_needed=true
	end
elseif key=="n"
then
	FeedEditName(Screen.menu:curr(), Screen.items)
	screen_reload_needed=true
elseif key=="u"
then
	feeds_screen_pos=Screen.menu:curr()
	if feeds_show_urls==true 
	then 
		feeds_show_urls=false
	else 
		feeds_show_urls=true
	end
	screen_reload_needed=true
else
	str=Screen.menu:onkey(key)
end

return str
end


-- the main front screen that shows all the available feeds
function SetupFeedsScreen()
local item, i
local Screen={}

Screen.menu=terminal.TERMMENU(Out, 2, 3, Out:width()-4, Out:length() - 10)
Screen.draw=FeedsScreenDraw
Screen.update=FeedsScreenUpdate
Screen.on_key=FeedsScreenOnKey
Screen.on_select=FeedsScreenOnSelect


Screen.items=FeedsGetList(paths.feeds_lst)
table.sort(Screen.items, FeedsSortByTime)
for i,item in ipairs(Screen.items)
do
	Screen.menu:add(FeedOrStreamTitle(Screen, item), item.url)
end

return Screen
end



function PlaylistOnSelect(Screen, url)
local i, item, played=true

	for i,item in ipairs(Screen.items)
	do
		--must do this first, as otherwise the item we are going to start playing is
		--going to be marked 'not played' and will wind up playing twice
		item.played=played	

		if item.url==url 
		then 
			PlayItem(item) 
			-- subsequent items will be set to not played, so
			-- they will play after this one
			played=false
		end
		
	end

screen_reload_needed=true
end



function PlaylistScreenDraw(Screen)

if #downloads == 0 
then
	Out:move(1, 2)
	Out:puts("  ~ePlaylist is currently empty, nothing to see here, move along~0\n")
	else
	Screen.menu:draw()
end
end


function PlaylistOnKey(Screen, key)
local url, str, item, i


str=""
if key=="c"
then
	downloads={}
else
	str=Screen.menu:onkey(key)
	Screen.menu:draw()
	PlaylistScreenDraw(Screen)
end

return str
end


function PlaylistFormatEntry(item)
local str

	if player ~= nil and player:pid()==item.pid 
	then 
		str="~w~eplaying~0      "..item.title 
	elseif downloader_pid > 0 and downloader_pid==item.pid
	then
		str="~rdownloading~0  "..item.title 
	elseif item.downloaded==true
	then
		str="~yready~0        "..item.title 
	else
		str="queued       "..item.title 
	end
return str
end


function PlaylistScreenUpdate(Screen)
local i, item

for i,item in ipairs(Screen.items)
do
	Screen.menu:update(PlaylistFormatEntry(item), item.url)
end

str=Screen.menu:curr()
if str ~=nil
then
	item=FindItemByURL(Screen.items, str)
	if item ~= nil then TextArea(Out:length() -5, 3, item.description) end
end


end



-- creates the screen that shows the playlist of items queued for playing
function SetupPlaylistScreen()
local Screen={}
local i, item

Screen.menu=terminal.TERMMENU(Out, 2, 3, Out:width()-4, Out:length() - 10)
Screen.items=downloads

Screen.update=PlaylistScreenUpdate
Screen.draw=PlaylistScreenDraw
Screen.on_select=PlaylistOnSelect
Screen.on_key=PlaylistOnKey

for i,item in ipairs(Screen.items)
do
	Screen.menu:add(PlaylistFormatEntry(item), item.url)
end

return Screen

end



-- creates a configuration item. If 'hide' is true, then this is not displayed to the user or saved, it's a 'fixed' setting. Otherwise this setting will be presented to the user on the settings screen with name 'title' and detailed description of 'desc'
function SettingCreate(name, value, title, desc, hide)
local item={}
local toks, token, seconds, str

if name==nil then return end

if settings[name]==nil
then
	item.name=name
	item.value=value
	item.title=title
	item.description=desc
	item.hide=hide
	settings[name]=item
else
	item=settings[name]
end


itype=type(item.value)
if item ~= nil
then
	if itype=="boolean"
	then
		if type(value) == "boolean" then item.value=value 
		elseif value == "true" then item.value=true
		else item.value=false
		end
	elseif itype=="number" then item.value=tonumber(value)
	else item.value=value
	end
end


-- some settings express a time period, and consist of a number followed by 'm' for minutes, 'h' for hours, 'd' for days, 'w' for weeks, or else are in seconds. We parse them here and set a value 'seconds' on the setting item for future use
str=""
seconds=0
if name == "cache_media_time" or name == "feed_update_time" or name == "feed_cache_time"
then
	toks=strutil.TOKENIZER(value, "s|m|h|d|w| |	", "ms")
	token=toks:next()
	while token ~= nil
	do
	if token=="s" or token==" " or token=="	"
	then
		seconds=seconds + tonumber(str) 
		str=""
	elseif token=="m"
	then
		seconds=seconds + tonumber(str) * 60
		str=""
	elseif token=="h"
	then
		seconds=seconds + tonumber(str) * 3600
		str=""
	elseif token=="d"
	then
		seconds=seconds + tonumber(str) * 3600 * 24
		str=""
	elseif token=="w"
	then
		seconds=seconds + tonumber(str) * 3600 * 24 * 7
		str=""
	else
		str=token
	end
	
	token=toks:next()
	end

	item.seconds=seconds
end

end


-- screen that prompts the user to alter a setting
function SettingsRead(setting)
local str=""

Out:clear()
Out:move(0,Out:length()-1)
Out:puts("~B~wEdit Setting: " .. setting.title .. "~>~0")

Out:move(0,0)
Out:puts("~B~wEdit Setting: " .. setting.title .. "~>~0\n\n")
Out:puts("~b~e" .. setting.description .. "~0\n\n")
Out:puts("Hit escape twice to cancel setting change\n\n")
Out:puts("Current value: " .. setting.value .. "\n\b")
str=Out:prompt("~eEnter new value:~0 ", setting.value)

--clear output so next screen isn't messed up
Out:clear()

return str
end


-- save settings in ~/.castclient/settings.conf. Note that hidden settings are fixed and are not saved.
function SettingsSave()
local key, item, S

S=stream.STREAM(paths.settings_conf, "w")
if S ~= nil
then
	S:lock()
	for key,item in pairs(settings)
	do
		if item.hide ~= true then S:writeln(item.name .. "=" .. tostring(item.value) .."\n"); end
	end
	S:unlock()
	S:close()
end

 if strutil.strlen(settings.proxy.value) then net.setProxy(settings.proxy.value) end
end


-- load settings from the config file
function SettingsLoad()
local str, itype, name, value, toks, S

S=stream.STREAM(paths.settings_conf, "r")
if S
then
	S:lock()
	str=S:readln()
	while str ~= nil
	do
		str=strutil.stripTrailingWhitespace(str)
		toks=strutil.TOKENIZER(str, "=")

		name=toks:next()
		value=toks:remaining()

		SettingCreate(name, value, "", "", false)
		str=S:readln()
	end

	S:unlock()
	S:close()
end

end


-- called when a setting item is selected from the settings menu
function SettingsOnSelect(Screen, config)
local toks, name, value, str

toks=strutil.TOKENIZER(config, "=")
name=toks:next()
value=toks:remaining()

item=Screen.items[name]

if type(item.value) == "boolean"
then
	item.value = not item.value
else
	str=SettingsRead(item)
	if str ~= nil then item.value=str end
end

SettingsSave()
screen_reload_needed=true
end



function SettingsMenuSortCompare(i1, i2)

if i1.name=="players" then return true end
if i2.name=="players" then return false end

if string.sub(i1.name, 1, 4) == "dev:" and string.sub(i2.name, 1, 4) ~= "dev:" then return true end
if string.sub(i1.name, 1, 4) ~= "dev:" and string.sub(i2.name, 1, 4) == "dev:" then return false end

return i1.name < i2.name 
end


function SettingsScreenDraw(Screen)
local str, item, toks

str=Screen.menu:curr()

if str ~=nil
then
	toks=strutil.TOKENIZER(str, "=")
	item=settings[toks:next()]
	if item ~= nil then TextArea(Out:length() -5, 3, item.description) end
end

Screen.menu:draw()
end



function SetupSettingsScreen()
local items, Menu
local Screen={}
local sorted={}


Screen.menu=terminal.TERMMENU(Out, 2, 3, Out:width()-4, Out:length() - 10)
Screen.items=settings

for key,item in pairs(settings)
do
	table.insert(sorted, item)
end

table.sort(sorted, SettingsMenuSortCompare)

for key,item in pairs(sorted)
do
	if item.hide ~= true then Screen.menu:add(string.format("%- 30s %s", item.title, item.value),  item.name.."=".. tostring(item.value)) end
end

Screen.on_select=SettingsOnSelect
Screen.draw=SettingsScreenDraw
return Screen

end



--main loop creates all the screens and then calls 'ProcessScreen' on the current one. keypresses handled within ProcessScreen can switch between these screens
function InteractiveModeMainLoop()
local SettingsScreen, PlaylistScreen, FeedsScreen
local Screen

	
while true
do

	if screen_reload_needed == true
	then
	SettingsScreen=SetupSettingsScreen()
	PlaylistScreen=SetupPlaylistScreen()
	FeedsScreen=SetupFeedsScreen()
	-- the feeds screen needs to remember it's position, so that as the user goes in and
	-- out of a feed they are still in the same place on the menu
	if feeds_screen_pos ~= nil then FeedsScreen.menu:setpos(feeds_screen_pos) end
	screen_reload_needed=false
	end


	if curr_screen == screen_settings
	then
		Screen=SettingsScreen
	elseif curr_screen == screen_playlist
	then
		Screen=PlaylistScreen
	else
		Screen=FeedsScreen
	end

	str=ProcessScreen(Screen)

	if str == settings.exit_key.value
	then 
		break
	elseif str == "" or str=="ESC"
	then
		--do nothing
	else 
		feeds_screen_pos=FeedsScreen.menu:curr()
		Screen.on_select(Screen, str)
	end
end

end



-- if a player program has been found on the current system, then add it to the list of available players
function PlayerAdd(media, setup)
local path, toks, cmd, args
local player={}

	toks=strutil.TOKENIZER(setup, " ")
	cmd=toks:next()
	args=toks:remaining()
	path=filesys.find(cmd, process.getenv("PATH"))

	if strutil.strlen(path) > 0
	then
		toks=strutil.TOKENIZER(media, ',')
		extn=toks:next()
		while extn ~= nil
		do
		player={}
		player.extn=extn
		player.path=path
		player.args=args 
		table.insert(players, player)
		extn=toks:next()
		end
	end
end



-- search for playback programs like mplayer or mpg123 that are installed on the current system
function FindPlayers(search_template)
local toks, media, player

toks=strutil.TOKENIZER(search_template, ";|:", "mQ")
while strutil.strlen(toks:remaining()) > 0
do
	media=toks:next()
	player=strutil.stripQuotes(toks:next())
	
	if strutil.strlen(player) > 0 then PlayerAdd(media, player) end
end

if #players == 0
then
	settings.players.description=settings.players.description .. "\n~rnone found on local system~0\n"
else
	settings.players.description=settings.players.description .. "\nFound: "
	for i, player in ipairs(players)
	do
	settings.players.description=settings.players.description .. " "..player.path
	end
end

end


function ApplicationInit()

now_playing.artist=""
now_playing.track=""

--SettingCreate("players", "mp3:'mpg123 -C -o (ao_type) -a (ao_id)';mp3:'mpg321 -R -o (ao_type) -a (ao_id)';mp3:'madplay --tty-control';mp3:ogg:ogg123 -d (ao_type) ;aac,m4a:ffmpeg -f alsa default -i;aac:mplayer -ao (dev) -really-quiet -cache 1024 -demuxer aac;m3u,pls:'cxine -ao (dev) -ap goom -s 200x100 +ss -webcast';*:'cxine -ao (dev) +ss -webcast';*:'mplayer -ao (dev) -quiet -slave';mp3,ogg,flac,aac:'play -q --magic'", "Players", "List of media players to search for and use.", false)
SettingCreate("players", "mp3:'mpg123 -C -o (ao_type) -a (ao_id)';mp3:'mpg321 -R -o (ao_type) -a (ao_id)';mp3:'madplay --tty-control';ogg:ogg123 -d (ao_type) ;mp3,aac,m4a,flac,opus:ffmpeg -f (ao_type) (ao_id)  -i;aac:mplayer -ao (dev) -really-quiet -cache 1024 -demuxer aac;m3u,pls:'cxine -ao (dev) -ap goom -s 200x100 +ss -webcast';*:'cxine -ao (dev) +ss -webcast';*:'mplayer -ao (dev) -quiet -slave';mp3,ogg,flac,aac:'play -q --magic'", "Players", "List of media players to search for and use.", false)

SettingCreate("dev:mpg123", "oss:/dev/dsp", "mpg123 output device", "Audio output device for mpg123. This will be /dev/dsp, /dev/dsp1 for oss, or hw:0, hw:1 for alsa.",false)
SettingCreate("dev:mpg321", "oss:/dev/dsp", "mpg321 output device", "Audio output device for mpg321. This will be /dev/dsp, /dev/dsp1 for oss, or hw:0, hw:1 for alsa.",false)
SettingCreate("dev:mplayer", "alsa:hw:1,alsa:hw:0,oss:/:dev/:dsp1,oss:/dev/dsp", "mplayer output device", "Audio output device for mplayer. Mplayer can accept a list of devices and use the first one that works. Format is <dev type>:<dev name>. e.g. oss:/dev/dsp or alsa:hw:1",false)
SettingCreate("dev:ffmpeg", "alsa:default", "ffmpeg output device", "Audio output device for ffmpeg. Format is <dev type>:<dev name>. e.g. oss:/dev/dsp or alsa:hw:1",false)
SettingCreate("dev:cxine", "alsa:0,alsa:1", "cxine output device", "Audio output device for cxine. CXine can accept a list of devices and use the first one that works. Format is <dev type>:<dev number>. e.g. oss:0 or alsa:1",false)
SettingCreate("exit_key", "Q", "Exit Key", "Key that exits application. Most keys are just indicated by their letter, uppercase for 'shift-key'. e.g. 'a' for the a key, 'A' for shift-a key. Some keys have names: 'ESC' for escape, HOME, INSERT, DELETE, WIN, MENU, F1, F2, F3...", false)
SettingCreate("stop_play_on_exit", true, "Stop playing on exit", "Kill off player app, stopping playback, if user exits castclient.",false)
SettingCreate("cache_media_time", "5d", "Max age of cached media", "Downloaded media files get deleted after this much time.",false)
SettingCreate("feed_update_time", "10m", "Check for feed updates time", "Time interval to check all feeds for updates, launches a background process that updates all configured feeds.",false)
SettingCreate("feed_cache_time", "5m", "Feed cache age", "If a feed is accessed (by selecting it in the feeds menu), check it for updates if it's older than this before displaying it.", false)
SettingCreate("proxy", "", "Proxy URL", "Proxy to use for all downloads. Format is: <protocol>:<user>:<password>@<host>:<port> protocols are: socks, http, https, sshtunnel.",false)

SettingCreate("handle_streams", false, "Handle streams internally", "Handle streams in castclient rather than handing off to a stream-aware player",false)
SettingCreate("stream_cache_size", "500k", "Cache Size for Streams", "Size of cache/buffer to use for streaming",false)
SettingCreate("stream_cache_fillto", "30", "Cache Fill Percent", "Fill cache to this percent before start playing",false)

SettingCreate("network_timeout", "500", "net timeout centisecs", "centisecs to wait for connection or read", false)
SettingCreate("xterm_title", "(artist): (track)", "Xterm Title", "If this value is non-blank then set title bar using Xterm escape sequences. Variables can be included in brackets, like: 'playing: (file)'", false)

SettingCreate("forward:mpg123", "..", "Forward cmd for mpg123", "send to mpg123 to fast-forward", true)
SettingCreate("rewind:mpg123", ",,", "Rewind cmd for mpg123", "send to mpg123 to rewind", true)

SettingCreate("play:mpg321", "load (url)\r\n", "Play cmd for mpg123", "send to mpg123 to fast-forward", true)
SettingCreate("forward:mpg321", "jump +20\r\n", "Forward cmd for mpg123", "send to mpg123 to fast-forward", true)
SettingCreate("rewind:mpg321", "jump -20\r\n", "Rewind cmd for mpg123", "send to mpg123 to rewind", true)

SettingCreate("forward:madplay", "F", "Forward cmd for madplay", "send to madplay to fast-forward", true)
SettingCreate("rewind:madplay", "B", "Rewind cmd for madplay", "send to madplay to rewind", true)


SettingCreate("play:mplayer", "loadfile (url)\r\n", "Play cmd for mplayer", "send to mplayer to fast-forward", true)
SettingCreate("forward:mplayer", "seek +10\r\n", "Forward cmd for mplayer", "send to mplayer to fast-forward", true)
SettingCreate("rewind:mplayer", "seek -10\r\n", "Rewind cmd for mplayer", "send to mplayer to rewind", true)

--[[
SettingCreate("play:cxine", "loadfile (url)\r\n", "Play cmd for cxine", "send to cxine to fast-forward", true)
SettingCreate("forward:cxine", "seek +10\r\n", "Forward cmd for cxine", "send to cxine to fast-forward", true)
SettingCreate("rewind:cxine", "seek -10\r\n", "Rewind cmd for cxine", "send to cxine to rewind", true)
]]--

FindPlayers(settings.players.value)


end



function ParseCommandLine(cmd_line)

for i,arg in ipairs(cmd_line)
do
	if arg=="-add"
	then
			cmd="add"
			url=cmd_line[i+1]
			cmd_line[i+1]=""
	elseif arg=="-import"
	then
			cmd="import"
			url=cmd_line[i+1]
			cmd_line[i+1]=""
	end
end

return cmd, url
end


function StartupConnectivityCheck()
local S

S=stream.STREAM("http://www.google.com/");
S:close();
end



-- MAIN STARTS HERE
ApplicationInit()
cmd,url=ParseCommandLine(arg)
SettingsLoad()



if cmd=="add" 
then 
	FeedsAdd(url) 
elseif cmd=="import"
then
	FeedsImport(url)
else
	process.lu_set("Error:Silent","y")
	process.sigwatch(13)
	process.setenv("PATH", "/usr/bin:/bin")

	if strutil.strlen(settings.proxy.value) then net.setProxy(settings.proxy.value) end

	StartupConnectivityCheck()

	FeedsUpdate()
	Out=terminal.TERM()
	terminal.utf8(2)
	Out:timeout(30)
	Out:move(0,0)
	Out:clear()

	InteractiveModeMainLoop()

	if player ~=nil and player:pid() > 0 and settings.stop_play_on_exit.value == true then player:stop_pgroup() end

	Out:move(0,0)
	Out:clear()
	Out:reset()
end

