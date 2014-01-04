{-# OPTIONS -fno-warn-missing-signatures #-}
{-# OPTIONS -fno-warn-type-defaults #-}

-- | Error and reply codes defined by http://www.ietf.org/rfc/rfc1459.txt
module IRC.Codes where

err_NOSUCHNICK = "401"
err_NOSUCHSERVER = "402"
err_NOSUCHCHANNEL = "403"
err_CANNOTSENDTOCHAN = "404"
err_TOOMANYCHANNELS = "405"
err_WASNOSUCHNICK = "406"
err_TOOMANYTARGETS = "407"
err_NOORIGIN = "409"
err_NORECIPIENT = "411"
err_NOTEXTTOSEND = "412"
err_NOTOPLEVEL = "413"
err_WILDTOPLEVEL = "414"
err_UNKNOWNCOMMAND = "421"
err_NOMOTD = "422"
err_NOADMININFO = "423"
err_FILEERROR = "424"
err_NONICKNAMEGIVEN = "431"
err_ERRONEUSNICKNAME = "432"
err_NICKNAMEINUSE = "433"
err_NICKCOLLISION = "436"
err_USERNOTINCHANNEL = "441"
err_NOTONCHANNEL = "442"
err_USERONCHANNEL = "443"
err_NOLOGIN = "444"
err_SUMMONDISABLED = "445"
err_USERSDISABLED = "446"
err_NOTREGISTERED = "451"
err_NEEDMOREPARAMS = "461"
err_ALREADYREGISTRED = "462"
err_NOPERMFORHOST = "463"
err_PASSWDMISMATCH = "464"
err_YOUREBANNEDCREEP = "465"
err_KEYSET = "467"
err_CHANNELISFULL = "471"
err_UNKNOWNMODE = "472"
err_INVITEONLYCHAN = "473"
err_BANNEDFROMCHAN = "474"
err_BADCHANNELKEY = "475"
err_NOPRIVILEGES = "481"
err_CHANOPRIVSNEEDED = "482"
err_CANTKILLSERVER = "483"
err_NOOPERHOST = "491"
err_UMODEUNKNOWNFLAG = "501"
err_USERSDONTMATCH = "502"

rpl_NONE = "300"
rpl_USERHOST = "302"
rpl_ISON = "303"
rpl_AWAY = "301"
rpl_UNAWAY = "305"
rpl_NOWAWAY = "306"
rpl_WHOISUSER = "311"
rpl_WHOISSERVER = "312"
rpl_WHOISOPERATOR = "313"
rpl_WHOISIDLE = "317"
rpl_ENDOFWHOIS = "318"
rpl_WHOISCHANNELS = "319"
rpl_WHOWASUSER = "314"
rpl_ENDOFWHOWAS = "369"
rpl_LISTSTART = "321"
rpl_LIST = "322"
rpl_LISTEND = "323"
rpl_CHANNELMODEIS = "324"
rpl_NOTOPIC = "331"
rpl_TOPIC = "332"
rpl_INVITING = "341"
rpl_SUMMONING = "342"
rpl_VERSION = "351"
rpl_WHOREPLY = "352"
rpl_ENDOFWHO = "315"
rpl_NAMREPLY = "353"
rpl_ENDOFNAMES = "366"
rpl_LINKS = "364"
rpl_ENDOFLINKS = "365"
rpl_BANLIST = "367"
rpl_ENDOFBANLIST = "368"
rpl_INFO = "371"
rpl_ENDOFINFO = "374"
rpl_MOTDSTART = "375"
rpl_MOTD = "372"
rpl_ENDOFMOTD = "376"
rpl_YOUREOPER = "381"
rpl_REHASHING = "382"
rpl_TIME = "391"
rpl_USERSSTART = "392"
rpl_USERS = "393"
rpl_ENDOFUSERS = "394"
rpl_NOUSERS = "395"
rpl_TRACELINK = "200"
rpl_TRACECONNECTING = "201"
rpl_TRACEHANDSHAKE = "202"
rpl_TRACEUNKNOWN = "203"
rpl_TRACEOPERATOR = "204"
rpl_TRACEUSER = "205"
rpl_TRACESERVER = "206"
rpl_TRACENEWTYPE = "208"
rpl_TRACELOG = "261"
rpl_STATSLINKINFO = "211"
rpl_STATSCOMMANDS = "212"
rpl_STATSCLINE = "213"
rpl_STATSNLINE = "214"
rpl_STATSILINE = "215"
rpl_STATSKLINE = "216"
rpl_STATSYLINE = "218"
rpl_ENDOFSTATS = "219"
rpl_STATSLLINE = "241"
rpl_STATSUPTIME = "242"
rpl_STATSOLINE = "243"
rpl_STATSHLINE = "244"
rpl_UMODEIS = "221"
rpl_LUSERCLIENT = "251"
rpl_LUSEROP = "252"
rpl_LUSERUNKNOWN = "253"
rpl_LUSERCHANNELS = "254"
rpl_LUSERME = "255"
rpl_ADMINME = "256"
rpl_ADMINLOC1 = "257"
rpl_ADMINLOC2 = "258"
rpl_ADMINEMAIL = "259"
