require("stream")
require("strutil")
require("dataparser")
require("process")
require("filesys")
require("terminal")
require("time")
require("hash")
require("net")

--casts_dir is our main 'working dir' where we store all the config files and downloadable items like rss feeds and media files
casts_dir=process.getenv("HOME").."/.castclient/"

settings={}

players={}
player_state_idle=0
player_state_play=1
player_state_pause=2
player_state_stopped=3
player_state=player_state_idle

feeds={}
feeds_last_update=0
feeds_update_pid=0

screen_feeds=0
screen_playlist=1
screen_settings=2
curr_screen=screen_feeds
screen_reload_needed=true


downloads={}
downloader_pid=0
player_pid=0
player=nil
now_playing=""
curr_chan=""


control_strings={}





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
if item.pid==pid then return item,i end
end

return nil,nil
end


function PlaybackPause()
if player_pid > 0
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
if player_pid > 0
then
		player_state=state_stopped
		player:continue()
		process.usleep(10000)
		player:stop()
end
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
function SelectPlayer(media_url)
local player, extn, str, pos,  

pos=string.find(media_url, "?")
if pos ~= nil then str=string.sub(media_url, 1, pos-1) 
else str=media_url
end

str=filesys.basename(str)
extn=filesys.extn(str)


if strutil.strlen(extn) > 1 then player=SelectPlayerGetFirstMatch(string.sub(extn, 2)) end
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
local args, dev, toks, ao_type, ao_id

args=player.args

str=LookupPlayerSetting(player.path, "out")
if str ~= nil then args=string.gsub(args, "%(out%)", str) end

str=LookupPlayerSetting(player.path, "dev")
if str ~= nil 
then
toks=strutil.TOKENIZER(str, ":")
ao_type=toks:next()
ao_id=toks:next()

args=string.gsub(args, "%(dev%)", str) 
if ao_type ~= nil then args=string.gsub(args, "%(ao_type%)", ao_type) end
if ao_id ~= nil then args=string.gsub(args, "%(ao_id%)", ao_id) end
end

return player.path.." "..args
end



-- start playing a playlist item by looking up a player program that can play the file type and launching that
function PlayItem(item)
local cmd, player_info, media_path

if player_pid > 0 then player:stop() end

media_path=CachePath(item.url)

--whatever happens update the mtime of the file, 'cos we tried to play it, so we don't want it cleaned up
filesys.touch(media_path)
player_info=SelectPlayer(item.url) 
cmd=SetupPlayerCommand(player_info) .. " "..  media_path

player=process.PROCESS(cmd, "pty noshell outnull")
if player ~= nil
then 
	player_pid=player:pid()	
	player_state=player_state_play

	--if a play command exists, then use it
	str=LookupPlayerSetting(player:exec_path(), "play")
	if str ~= nil 
	then 
		cmd=string.gsub(str, "%(url%)", media_path)
		player:send(cmd) 
	end

	now_playing=item.title
	item.pid=player_pid
	item.played=true
	StatusBarDisplay()
end

screen_reload_needed=true
end



-- kill the current player program and start playing the previous item in the playlist
function PlaybackPrev()
local i, item, pos

if player_pid > 0 
then 
	item,pos=PlaybackGetCurrItem(downloads, player_pid)
	PlaybackStop() 
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

if player_pid > 0 
then 
	item=PlaybackGetCurrItem(downloads, player_pid)
	PlaybackStop() 
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

if player_pid > 0 
then 
	item=PlaybackGetCurrItem(downloads, player_pid)
	PlaybackStop() 
	PlayItem(item) 
end

screen_reload_needed=true
end




-- lookup a 'rewind' command for the current player program, and if there is one send it to the program
function PlaybackRewind()
local cmd

if player_pid > 0 
then 
	cmd=LookupPlayerSetting(player:exec_path(), "rewind")
	if cmd ~= nil then player:send(cmd) end
end

end

-- lookup a 'fast forward' command for the current player program, and if there is one send it to the program
function PlaybackForward()
local cmd

if player_pid > 0 
then 	
	cmd=LookupPlayerSetting(player:exec_path(), "forward")
	if cmd ~= nil then player:send(cmd) end
end

end



-- find item in a list of items by it's url. Depending on the list the items could be RSS feeds or podcast episodes/media files
function FindItemByURL(items, url)
local i, item

for i,item in ipairs(items)
do
	if item.url==url then return item,i end
end

return nil
end


-- generate a unique file path to cache a downloadable item (RSS feed or media file) under
function CachePath(url)
local str, urlhash, fname, toks

toks=strutil.TOKENIZER(filesys.basename(url), "?")
fname=toks:next()

if strutil.strlen(fname) ==0 then fname="feed" end

urlhash=hash.hashstr(url, "md5", "hex");

str=casts_dir .. urlhash .. "-".. fname

return str
end


function CachedFeedIsOld(path)

	if time.secs() - tonumber(filesys.mtime(path)) > 600 then return true end

	return false
end



-- this function checks if a url is in the cache. If not, or if it's older than a certain 
-- amount, it downloads the url to the cache. If the cache dir is not writable it returns 
-- the original url, otherwise it returns a path to the downloaded file
function FeedFromCache(url)
local path, done_path

path=CachePath(url)
done_path=path..".rss"

if filesys.exists(done_path) == true or CachedFeedIsOld(done_path)
then
	filesys.copy(url, path)
	filesys.rename(path, done_path)
end

if filesys.exists(done_path) == true then return done_path end

return url
end



function FeedsParseItem(input)
local toks, item, str

	toks=strutil.TOKENIZER(input, "\\S", "Q")

	item={}
	item.title=""
	item.updated=0
	item.url=strutil.stripTrailingWhitespace(toks:next())

	str=toks:next()
	while str ~= nil
	do
		if string.sub(str, 1, 8) == "updated=" then item.updated=tonumber(string.sub(str, 9)) end
		if string.sub(str, 1, 6) == "title=" then item.title=strutil.htmlUnQuote(strutil.unQuote(string.sub(str, 7))) end
	str=toks:next()
	end

return item
end



function FeedsSortByTime(i1, i2)
return i1.updated > i2.updated
end


-- check if it's time to update the feeds.lst file by connecting to RSS feed urls and checking if they've changed
function FeedsRequireUpdate()
local mtime

if #feeds < 1 then return true end

mtime=filesys.mtime(casts_dir.."/feeds.lst")
if (now - mtime ) > settings.feed_update_time.seconds then return true end

if filesys.size(casts_dir.."/feeds.new") > 0 then return true end

return false
end


-- load list of available feeds from the feeds.lst file
function FeedsGetList()
local S, str

str=casts_dir .. "/feeds.lst"

now=time.secs()
if FeedsRequireUpdate() ~= true then return feeds,false end

feeds_last_update=now


feeds={}
S=stream.STREAM(str, "r")
if S ~= nil
then
	str=S:readln()
	while str ~= nil
	do
	if strutil.strlen(str) > 0 then table.insert(feeds, FeedsParseItem(str)) end
	str=S:readln()
	end
	S:close()
end

return feeds,true
end


-- formats a feed to be displayed on the main feed screen, coloring it to indicate recently updated feeds
function FeedTitle(item)
local str, daysecs, diff
local timecolor=""

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

if strutil.strlen(item.title) > 0
then
	str=str .. item.title
else
	str=str .. "~r" .. item.url .. "  (pending)~0"
end

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


-- get a feed RSS file from cache, or download if cache is too old
function FeedGet(url)
local S, P, I, choice, str
local latest=0
local chan={}
local items={}

chan.title=""
chan.description=""
chan.updated=0

url=FeedFromCache(url)
S=stream.STREAM(url, "r")
if S ~= nil
then
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
		if latest < item.when then latest=item.when end
		table.insert(items, item)
	end
	I=P:next()
end
end
end

if chan.updated==0 then chan.updated=latest end

return chan,items
end


-- this is called by the feeds update process and writes out the list of feeds to a new feeds.lst file
function FeedsSave(feed_list)
local i, item, S, str

S=stream.STREAM(casts_dir.. "feeds.lst+", "w")
if S ~= nil
then
	S:waitlock()
	for i,item in ipairs(feed_list) 
	do
		str=string.format("%s title=%s updated=%d\n", item.url, strutil.quoteChars(item.title, "' 	"), item.updated) 
		S:writeln(str)
	end

	filesys.unlink(casts_dir.."feeds.lst")
	filesys.rename(casts_dir.."feeds.lst+", casts_dir.."feeds.lst")
	S:close()
end

end


--feeds are added to a feeds.new file to prevent two processes trying to write to feeds.lst file at the same time. The feeds update process will then pull in any items in feeds.new when it's free to do so
function FeedsAdd(url)
local S, str

url=TranslateFeed(url)

filesys.mkdir(casts_dir)
str=casts_dir .. "/feeds.new"

S=stream.STREAM(str, "a")
if S ~= nil
then
	S:waitlock()
	S:writeln(url.."\n")
	S:close()
end

screen_reload_needed=true
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

if strutil.strlen(url) > 0 then FeedsAdd(url) end

--clear output so next screen isn't messed up
Out:clear()
end


-- if a feed has been added to the list of feeds it goes in a 'feeds.new' file. This is to prevent two processes trying to write to the feeds.lst file at the same time. In this scheme only the feeds update process edits the feeds.lst file, but it checks if a feeds.new file exists and imports it into the main feeds.lst file
function FeedsImportNew()
local FeedsS, NewFeedsS, str, chan

FeedsS=stream.STREAM(casts_dir.."/feeds.lst", "a")
if FeedsS ~= nil
then
	FeedsS:waitlock()
	NewFeedsS=stream.STREAM(casts_dir.."/feeds.new", "rw")
	if NewFeedsS ~= nil
	then
	NewFeedsS:waitlock()

	str=NewFeedsS:readln()
	while str ~= nil
	do
		str=strutil.stripTrailingWhitespace(str)
		chan=FeedGet(str)
		str=string.format("%s title=%s updated=%d\n", str, strutil.quoteChars(chan.title, "' 	"),  chan.updated) 
		FeedsS:writeln(str)
		str=NewFeedsS:readln()
	end

	NewFeedsS:truncate()
	NewFeedsS:close()
	end
	FeedsS:close()
end
end


-- this function is called within a forked-off subprocess, hence the os.exit() at the end of it
-- it's job is to download and import feed urls to see if any new items have appeared
function FeedsUpdateSubprocess()
local i, feed, chan, items

	FeedsImportNew()
	feed_list=FeedsGetList()

	for i,feed in ipairs(feed_list)
	do
		if strutil.strlen(feed.url) > 0
		then
		chan,items=FeedGet(feed.url)
		if chan ~= nil
		then
		feed.title=chan.title
		feed.description=chan.description
		feed.updated=chan.updated
		feed.size=#items
		end
		end
	end

	FeedsSave(feed_list)
	os.exit(1)
end


-- this function updates the feeds.lst status file in the .castclient directory
function FeedsUpdate()
local lockfile

lockfile=stream.STREAM(casts_dir.."/update.lck", "w")
if lockfile 
then
	if lockfile:lock()
	then
		feeds_update_pid=process.xfork("innull")

		--if feeds_update_pid == 0 after a form, then we're in the child process
			if feeds_update_pid == 0 
			then 
				lockfile:writeln(string.format("%d\n", process.getpid()))
				FeedsUpdateSubprocess() 
			end

	end
	lockfile:close()
end

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

str=casts_dir .. "/*"
files=filesys.GLOB(str)
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


pid=process.childExited()
if pid ~= 0
then
	retval=true
	if pid==downloader_pid then downloader_pid=0 end
	if pid==feeds_update_pid then feeds_update_pid=0 end
	if pid==player_pid 
	then 
		player_pid=0 
		player_state=player_state_idle
		now_playing=""
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
			screen_reload_needed=true
		end
end

if player_pid==0 then PlaybackNext() end

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
	if item.pid == player_pid then return i end
end

return 0
end



function HelpDisplay()
	Out:clear()
	Out:move(0,1)
	Out:puts("~bKey Bindings~0\n");
	Out:puts("    ?            This help\n")
	Out:puts("    escape       Press escape twice to exit a menu or the app\n")
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
	Out:puts("    ctrl-left    Skip to previous playlist item\n")
	Out:puts("    ctrl-right   Skip to next playlist item\n")

	Out:puts("\n")
	Out:puts("~ePRESS ANY KEY TO CLOSE THIS SCREEN\n")

	Out:flush()
	ch=Out:getc()
	while strutil.strlen(ch) ==0
	do
		ch=Out:getc()
	end
	
	Out:clear()
end


-- draw the status bar at the bottom of the screen
function StatusBarDisplay()
local str, item


str="~C"
str=str..string.format("Playlist: % 4d items     ", #downloads)
if player_state==player_state_play
then
	str=str..string.format("~wPLAYING: %d/%d %s", NowPlayingItemNo(), #downloads, now_playing)
elseif player_state==player_state_pause
then
	str=str.."~rPAUSED: " .. now_playing
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

Out:cork()

DrawMenuSelection()

if Screen.update ~= nil then Screen:update() end
if Screen.draw ~= nil then Screen:draw() end

StatusBarDisplay()
Out:flush()
end


-- process the current screen. This loops until a keypress or other event needs handling
function ProcessScreen(Screen)
local ch, str

if process.sigwatch ~= nil then process.sigwatch(28) end
ScreenRefresh(Screen)

ch=Out:getc()
while str==nil
do
	if ch ~= ""
	then

	if ch=="ESC" or ch=="BACKSPACE"
	then 
		--clear output so next screen isn't messed up
		Out:clear()
		return nil 
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
	elseif ch=="SHIFT_LEFT" or ch==","
	then
		PlaybackRewind()
	elseif ch=="SHIFT_RIGHT" or ch=="."
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

	if process.sigcheck ~= nil and process.sigcheck(28) == true
	then
		screen_reload_needed=true
		Out:clear()
		return ""
	end 

	if ch ~= "" or PlaylistProcess() == true then ScreenRefresh(Screen) end

	ch=Out:getc()
end

return str
end


-- this doesn't touch any items in the menu, but it does update the description text below the menu
-- as the user moves from episode to episode
function FeedItemsScreenUpdate(Screen)
local str, item

Out:move(0, 0)
str=string.format("~B~y   ~e%s~0~B~w  %d items~>~0\n", curr_chan.title, #Screen.items)
Out:puts(str);

str=Screen.menu:curr()
if str ~=nil
then
	item=FindItemByURL(Screen.items, str)
	if item ~= nil then TextArea(Out:length() -5, 3, item.description) end
end

Screen.menu:draw()
end


-- if a feed is selected on the feed screen, then this screen is displayed showing the episodes/playable items
function FeedItemsMenu(url, feeds)
local items, item, Menu, i, toks, str, choice
local Screen={}

Out:clear()
curr_chan,items=FeedGet(url)
Screen.menu=terminal.TERMMENU(Out, 2, 3, Out:width()-4, Out:length() - 10)
Screen.items=items
Screen.draw=FeedItemsScreenUpdate

for i,item in ipairs(items)
do
	str=time.formatsecs("%Y/%m/%d", item.when)  .. "  ~w".. item.title .."~0"
	-- if using a version of libuseful that has a width setter, then we can be smarter about what we display
	if Screen.menu.width ~= nil
	then
	if strutil.strlen(str) < (Screen.menu:width() - 34) 
	then 
		str=str.. "    " .. item.description 
		str=string.sub(str, 1, Screen.menu:width()-4)
		str=string.gsub(str, "\n", " ")
	end
	end
	Screen.menu:add(str, item.url)
end

while true
do
	choice=ProcessScreen(Screen)
	if choice==nil then break end

	item=FindItemByURL(items, choice)
	if item ~= nil then PlaylistAdd(item) end
end

end



function FeedsScreenLoadPending(Screen)
local NewFeedsS, str, added=false

NewFeedsS=stream.STREAM(casts_dir.."/feeds.new", "r")
if NewFeedsS ~= nil
then
	str=NewFeedsS:readln()
	while str ~= nil
	do
	str=strutil.stripTrailingWhitespace(str)
	if Screen.items[str] == nil
	then
		feed={}
		feed.title=""
		feed.updated=0
		feed.url=str
		Screen.items[feed.url]=feed
		Screen.menu:add(FeedTitle(feed), feed.url)
		added=true
	end
	str=NewFeedsS:readln()
	end
	NewFeedsS:close()
end

return added
end




function FeedsScreenUpdate(Screen)
local new_items, i, item, new_item, str
local updated=false

new_items,updated=FeedsGetList()

if updated==true 
then 
for i,item in ipairs(Screen.items) 
do 
  new_item=FindItemByURL(new_items, item.url) 
  if new_item ~= nil and new_item.updated > item.updated 
  then 
    Screen.items[i]=new_item 
    Screen.menu:update(FeedTitle(new_item), new_item.url) 
  end 
end


--load pending items into screen.items directly because they are not
--updates of existing items
if FeedsScreenLoadPending(Screen) then updated=true end

screen_reload_needed=true
if updated == true then Screen.menu:draw() end
end

end


function FeedsScreenDraw(Screen )

if #Screen.items > 0
then
	Screen.menu:draw()
else
	Out:move(2, 2)
	Out:puts("~eNo feeds configured. Press 'a' to add one~0\n")
end
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
Screen.on_select=FeedItemsMenu


Screen.items=FeedsGetList()
table.sort(Screen.items, FeedsSortByTime)
for i,item in ipairs(Screen.items)
do
	Screen.menu:add(FeedTitle(item), item.url)
end

return Screen
end



function PlaylistOnSelect(url, items)
local i, item

	for i,item in ipairs(items)
	do
		if item.url==url 
		then 
			PlayItem(item) 
			break
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

	if player_pid > 0 and player_pid==item.pid 
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
if name == "cache_media_time" or name == "feed_update_time"
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
local str

Out:clear()
Out:move(0,Out:length()-1)
Out:puts("~B~wEdit Setting: " .. setting.title .. "~>~0")

Out:move(0,0)
Out:puts("~B~wEdit Setting: " .. setting.title .. "~>~0\n\n")
Out:puts(setting.description.."\n\n")
Out:puts("Hit escape twice to cancel setting change\n\n")
str=Out:prompt("~eEnter value:~0 ", setting.value)

--clear output so next screen isn't messed up
Out:clear()

return str
end


-- save settings in ~/.castclient/settings.conf. Note that hidden settings are fixed and are not saved.
function SettingsSave()
local key, item, S

S=stream.STREAM(casts_dir.."settings.conf", "w")
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

S=stream.STREAM(casts_dir.."settings.conf", "r")
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
function SettingsOnSelect(config, items)
local toks, name, value, str

toks=strutil.TOKENIZER(config, "=")
name=toks:next()
value=toks:remaining()

item=items[name]

if type(item.value) == "boolean"
then
	item.value = not item.value
else
	str=SettingsRead(item)
	if str ~= nil then item.value=str end
end

SettingsSave()
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

	if str == nil 
	then 
		break
	elseif str == ""
	then
		--do nothing
	else 
		Screen.on_select(str, Screen.items)
		screen_reload_needed=true
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

SettingCreate("players", "mp3:'mpg123 -C -o (ao_type) -a (ao_id)';mp3:'mpg321 -R -o (ao_type) -a (ao_id)';mp3:'madplay --tty-control':ogg:ogg123;*:'cxine -ao (dev) +ss';*:'mplayer -ao (dev) -quiet -slave';mp3,ogg,flac,aac:'play -q --magic'", "Players", "List of media players to search for and use.", false)

SettingCreate("dev:mpg123", "oss:/dev/dsp", "mpg123 output device", "Audio output device for mpg123. This will be /dev/dsp, /dev/dsp1 for oss, or hw:0, hw:1 for alsa.",false)
SettingCreate("dev:mpg321", "oss:/dev/dsp", "mpg321 output device", "Audio output device for mpg321. This will be /dev/dsp, /dev/dsp1 for oss, or hw:0, hw:1 for alsa.",false)
SettingCreate("dev:mplayer", "alsa:hw:1,alsa:hw:0,oss:/:dev/:dsp1,oss:/dev/dsp", "mplayer output device", "Audio output device for mplayer. Mplayer can accept a list of devices and use the first one that works. Format is <dev type>:<dev name>. e.g. oss:/dev/dsp or alsa:hw:1",false)
SettingCreate("dev:cxine", "alsa:0,alsa:1", "cxine output device", "Audio output device for cxine. CXine can accept a list of devices and use the first one that works. Format is <dev type>:<dev number>. e.g. oss:0 or alsa:1",false)
SettingCreate("stop_play_on_exit", true, "Stop playing on exit", "Kill off player app, stopping playback, if user exits castclient.",false)
SettingCreate("cache_media_time", "5d", "Max age of cached media", "Downloaded media files get deleted after this much time.",false)
SettingCreate("feed_update_time", "5m", "Check for feed updates time", "Time interval to check all feeds for updates.",false)
SettingCreate("proxy", "", "Proxy URL", "Proxy to use for all downloads. Format is: <protocol>:<user>:<password>@<host>:<port> protocols are: socks, http, https, sshtunnel.",false)

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

SettingCreate("play:cxine", "loadfile (url)\r\n", "Play cmd for cxine", "send to cxine to fast-forward", true)
SettingCreate("forward:cxine", "seek +10\r\n", "Forward cmd for cxine", "send to cxine to fast-forward", true)
SettingCreate("rewind:cxine", "seek -10\r\n", "Rewind cmd for cxine", "send to cxine to rewind", true)


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
	end
end

return cmd, url
end



-- MAIN STARTS HERE
ApplicationInit()
cmd,url=ParseCommandLine(arg)
SettingsLoad()


if cmd=="add" 
then 
	FeedsAdd(url) 
else
	process.lu_set("Error:Silent","y")
	if strutil.strlen(settings.proxy.value) then net.setProxy(settings.proxy.value) end

	FeedsUpdate()
	Out=terminal.TERM()
	terminal.utf8(0)
	Out:timeout(100)
	Out:move(0,0)
	Out:clear()

	InteractiveModeMainLoop()

	if player_pid > 0 and settings.stop_play_on_exit.value == true then player:stop() end

	Out:move(0,0)
	Out:clear()
	Out:reset()
end

