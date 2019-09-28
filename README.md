SYNOPSIS
========

castclient.lua is a primitive RSS Feed reader that can download and play podcasts and bitchute videos. It's written in lua and requires libUseful and libUseful-lua to be installed. It uses an external program to play downloaded media, and currently searches for mpg123, ogg123, mplayer or cxine to use for this. Currently the only playback control is 'pause' (except for Xwindows players like cxine or mplayer that have their own keyboard controls). 

castclient.lua is not (yet) a podcatcher, and can thus only play items that are currently in an RSS feed file. It downloads them when the user requests to play them.

USAGE
=====

castclient.lua is a lua script and can be run as 'lua castclient.lua', or you can use linux's 'binfmt' system to automatically run it with lua.

castclient.lua comes with an initial feeds.lst file that can be copied to ~/.castclient/feeds.lst. Alternatively you can add feeds by pressing the 'a' key and entering the URLs when prompted. Pressing the '?' key will display a list of keystrokes that are used.

For bitchute channels you have to enter the url to the channel (usually https://www.bitchute.com/channels/<chan name>/) and castclient.lua will find the RSS feed for the channel.

LICENSE
=======

castclient.lua is released under the GPLv3 and is copyright Colum Paget 2019
