#!/usr/bin/wish8.6
# Irken - dlowe@dlowe.net
if {[catch {package require tls} cerr]} {
    puts stderr "Could not load TLS library.  Please run: sudo apt install tcl-tls"
    exit 1
}

# Hooks
set ::hooks [dict create]
proc hook {op name args} {
    dict lappend ::hooks $name
    set hook [dict get $::hooks $name]
    switch -- $op {
        "prepend" -
        "append" {
            if {[llength $args] != 3} {
                error "Invalid # of args - hooks (pre|a)ppend hookname thishook params body"
            }
            if {[set hookidx [lsearch -index 0 $hook [lrange $args 0 0]]] == -1} {
                dict set ::hooks $name [linsert $hook [expr {$op eq "prepend" ? 0 : "end"}] $args]
            } else {
                dict set ::hooks $name [lreplace $hook $hookidx $hookidx $args]
            }
        }
        "remove" {dict set ::hooks $name [lsearch -all -inline -not -index 0 $hook $hookname]}
        "exists" {expr {$hook ne {}}}
        "clear" {dict set ::hooks $name {}}
        "call" {foreach hookproc $hook {apply [lrange $hookproc 1 2] {*}$args}}
    }
}

# A chanid is $serverid for the server channel, $serverid/$channel for channel display.
proc chanid {serverid chan} { if {$chan eq ""} {return $serverid} {return $serverid/$chan} }
proc serverpart {chanid} {lindex [split $chanid {/}] 0}
proc channelpart {chanid} {lindex [split $chanid {/}] 1}
proc ischannel {chanid} {regexp -- {^[&#+!][^ ,\a]{0,49}$} [channelpart $chanid]}

# ::config is a dict keyed on serverid containing config for each server, loaded from a file.
set ::config {}
set configpath $::env(HOME)/.config/irken/config.tcl
file mkdir [file dirname $configpath]
proc server {serverid args}  {dict set ::config $serverid $args}
if {! [file exists $configpath]} {
    if {[catch {open $configpath w} fp]} {
        puts stderr "Couldn't write default config.  Exiting."
        exit 1
    }
    puts $fp {server "Freenode" -host chat.freenode.net -port 6667 -ssl false -nick tcl-$::env(USER) -user $::env(USER) -autoconnect True -autojoin {\#tcl}}
    close $fp
}
source $configpath

# ::servers is a dict keyed on fd containing the serverid
set ::servers {}
# ::fds is a dict keyed on serverid containing the fd and current nick
set ::serverinfo {}
# ::channeltext is a dict keyed on chanid containing channel text with tags
set ::channeltext {}
# ::channelinfo is a dict keyed on chanid containing topic, user list, input history, place in the history index.
set ::channelinfo {}
# ::active is the chanid of the shown channel.
set ::active {}

set ::nickprefixes "@%+&~"

# interface setup
proc icon {path} { return [image create photo -format png -data [exec -- convert -background none -geometry 16x16 $path "png:-" | base64]] }
set font "Monospace 10"
ttk::panedwindow .root -orient horizontal
.root add [ttk::frame .navframe -width 170] -weight 0
.root add [ttk::frame .mainframe -width 300 -height 300] -weight 1
.root add [ttk::frame .userframe -width 140] -weight 0
ttk::treeview .nav -show tree -selectmode browse
bind .nav <<TreeviewSelect>> selectchan
.nav column "#0" -width 150
.nav tag config server -font $font -image [icon "/usr/share/icons/Humanity/apps/22/gnome-network-properties.svg"]
.nav tag config channel -font $font -image [icon "/usr/share/icons/Humanity/apps/22/system-users.svg"]
.nav tag config direct -font $font -image [icon "/usr/share/icons/Humanity/stock/48/stock_person.svg"]
.nav tag config disabled -foreground gray
.nav tag config highlight -foreground green
.nav tag config unread -foreground orange
ttk::entry .topic -takefocus 0 -font $font
text .t -height 30 -wrap word -font $font -state disabled -tabs "[expr {25 * [font measure $font 0]}] right [expr {26 * [font measure $font 0]}] left"
.t tag config bold   -font "$font bold"
.t tag config italic -font "$font italic"
.t tag config self   -foreground darkgray
.t tag config highlight  -foreground green
.t tag config warning  -foreground red -font "$font italic"
.t tag config hlink -foreground blue -underline 1
.t tag bind hlink <Button-1> {exec -ignorestderr -- xdg-open [.t get {*}[.t tag prevrange hlink @%x,%y]]}
ttk::frame .cmdline
ttk::label .nick -padding 3
ttk::entry .cmd -validatecommand {historybreak} -font $font
ttk::treeview .users -show tree -selectmode browse
.users tag config ops -foreground red
.users tag config halfops -foreground pink
.users tag config admin -foreground orange
.users tag config voice -foreground blue
.users tag config quiet -foreground gray
.users column "#0" -width 140
ttk::label .chaninfo -relief groove -border 2 -justify center -padding 2 -anchor center
pack .nav -in .navframe -fill both -expand 1
pack .topic -in .mainframe -side top -fill x
pack .nick -in .cmdline -side left
pack .cmd -in .cmdline -side right -fill x -expand 1
pack .cmdline -in .mainframe -side bottom -fill x -pady 5
pack .t -in .mainframe -fill both -expand 1
pack .chaninfo -in .userframe -side top -fill x -padx 10 -pady 5
pack .users -in .userframe -fill both -expand 1 -padx 1 -pady 5
pack .root -fill both -expand 1
bind . <Escape> {exec wish $argv0 &; exit}
bind . <Prior> [list .t yview scroll -1 page]
bind . <Next> [list .t yview scroll 1 page]
bind . <Control-Prior> [list ttk::treeview::Keynav .nav up]
bind . <Control-Next> [list ttk::treeview::Keynav .nav down]
bind .topic <Return> setcurrenttopic
bind .cmd <Return> returnkey
bind .cmd <Up> [list history up]
bind .cmd <Down> [list history down]

proc irctolower {str} {return [string map [list \[ \{ \] \} \\ \| \~ \^] [string tolower $str]]}
proc ircstrcmp {a b} {return [string compare [irctolower $a] [irctolower $b]]}
proc rankeduser {entry} {
    if {[set rank [lsearch [list ops halfops admin voice] [lindex $entry 1]]] == -1} {
        set rank 9
    }
    return $rank[lindex $entry 0]
}
proc usercmp {a b} {
    return [ircstrcmp [rankeduser $a] [rankeduser $b]]
}
proc sorttreechildren {window root} {
    set items [lsort [$window children $root]]
    $window detach $items
    set count [llength $items]
    for {set i 0} {$i < $count} {incr i} {
        $window move [lindex $items $i] $root $i
    }
}

proc setchantopic {chanid text} {
    dict set ::channelinfo $chanid topic $text
    if {$chanid eq $::active} {
        .topic delete 0 end
        .topic insert 0 $text
    }
}

proc updatechaninfo {chanid} {
    if {[ischannel $chanid]} {
        set users {}
        catch {dict get $::channelinfo $chanid users} users
        .chaninfo configure -text "[llength $users] users"
    } else {
        .chaninfo configure -text {}
    }
}

proc historybreak {} {
    dict set ::channelinfo $::active historyidx {}
    return 1
}

proc history {op} {
    set oldidx [dict get $::channelinfo $::active historyidx]
    set idx $oldidx
    set cmdhistory [dict get $::channelinfo $::active cmdhistory]
    switch -- $op {
        "up" {set idx [expr {$idx eq {} ? 0 : $idx == [llength $cmdhistory] - 1 ? $oldidx : $idx + 1}]}
        "down" {set idx [expr {$idx eq {} || $idx == 0 ? "" : $idx - 1}]}
    }
    if {$idx eq $oldidx} {
        return
    }
    dict set ::channelinfo $::active historyidx $idx
    .cmd configure -validate none
    .cmd delete 0 end
    if {$idx ne {}} {
        .cmd insert 0 [lindex $cmdhistory $idx]
    }
    .cmd configure -validate key
}

proc setchanusers {chanid users} {
    set users [lsort -command usercmp $users]
    dict set ::channelinfo $chanid users $users
    if {$chanid ne $::active} {
        return
    }
    updatechaninfo $chanid
    set items [lmap x $users {lindex $x 0}]
    .users detach $items
    set count [llength $items]
    for {set i 0} {$i < $count} {incr i} {
        .users move [lindex $items $i] $root $i
    }
}

# users should be {nick modes}
proc addchanuser {chanid user} {
    set impliedmode {}
    switch -- [string range $user 0 0] {
        "@" {set impliedmode {ops}}
        "%" {set impliedmode {halfops}}
        "&" {set impliedmode {admin}}
        "+" {set impliedmode {voice}}
        "~" {set impliedmode {quiet}}
    }
    if {$impliedmode ne {}} {
        set user [string range $user 1 end]
    }
    set userentry [list $user $impliedmode]
    set users {}
    if {[dict exists $::channelinfo $chanid users]} {
        set users [dict get $::channelinfo $chanid users]
    }
    if {[set pos [lsearch -index 0 $users $user]] != -1} {
        if {$userentry eq [lindex $users $pos]} {
            # exact match - same prefix with user
            return
        }
        # update user prefix
        set users [lreplace $users $pos $pos $userentry]
        if {$chanid eq $::active} {
            .users tag remove [lindex [lindex $users $pos] 1] $user
            .users tag add $impliedmode $user
        }
    } else {
        # entirely new user
        lappend users $userentry
        if {$chanid eq $::active} {
            .users insert {} end -id $user -text $user -tag $impliedmode
        }
    }
    setchanusers $chanid $users
}

proc remchanuser {chanid user} {
    set user [string trimleft $user $::nickprefixes]
    set users [dict get $::channelinfo $chanid users]
    set idx [lsearch -index 0 $users $user]
    if {$idx != -1} {
        set users [lreplace $users $idx $idx]
        dict set ::channelinfo $chanid users $users
        if {$chanid eq $::active} {
            .users delete $user
        }
    }
}

proc addchantext {chanid nick text args} {
    lappend newtext "\[[clock format [clock seconds] -format %H:%M:%S]\]" {} "\t$nick\t" "bold $args"
    set textstart 0
    if {[regexp -all -indices {https?://[-a-zA-Z0-9@:%_/\+.~#?&=]+} $text match] != 0} {
        foreach {start end} $match {
            lappend newtext [string range $text $textstart $start-1] $args
            lappend newtext [string range $text $start $end] [concat hlink $args]
            set textstart [expr {$end + 1}]
        }
    }
    lappend newtext "[string range $text $textstart end]" $args
    dict append ::channeltext $chanid " $newtext"
    if {$chanid ne $::active} {
        if {[lsearch $args highlight] != -1} {
            .nav tag add highlight $chanid
        } else {
            .nav tag add unread $chanid
        }
        return
    }
    set atbottom [expr {[lindex [.t yview] 1] == 1.0}]
    .t configure -state normal
    .t insert end {*}$newtext
    if {$atbottom} {
        .t yview end
    }
    .t configure -state disabled
}

proc selectchan {} {
    set chanid [.nav selection]
    if {$chanid eq $::active} {
        return
    }
    .nav focus $chanid
    .nav tag remove unread $chanid
    .nav tag remove highlight $chanid
    set ::active $chanid
    .t configure -state normal
    .t delete 1.0 end
    if {[dict get $::channeltext $chanid] ne ""} {
        .t insert end {*}[dict get $::channeltext $chanid]
        .t yview end
    }
    .t configure -state disabled
    .topic delete 0 end
    if {![catch {dict get $::channelinfo $chanid topic} topic]} {
        .topic insert 0 $topic
    }
    .users delete [.users children {}]
    if {[ischannel $chanid]} {
        if {![catch {dict get $::channelinfo $chanid users} users]} {
            foreach user $users {
                .users insert {} end -id [lindex $user 0] -text [lindex $user 0] -tag [lindex $user 1]
            }
        }
    }
    updatechaninfo $chanid
    if {[dict exists $::serverinfo [serverpart $chanid] nick]} {
        .nick configure -text [dict get $::serverinfo [serverpart $chanid] nick]
    } else {
        .nick configure -text [dict get $::config [serverpart $chanid] -nick]
    }

    wm title . "Irken - $::active"
}

proc ensurechan {chanid tags} {
    if {[dict exists $::channelinfo $chanid]} {
        return
    }
    set serverid [serverpart $chanid]
    set name [channelpart $chanid]
    set tag {direct}
    if {$name eq ""} {
        set tag {server}
    } elseif {[ischannel $chanid]} {
        set tag {channel}
    }
    dict set ::channeltext $chanid {}
    dict set ::channelinfo $chanid [dict create cmdhistory {} historyidx {} topic {} users {}]
    if {$name eq {}} {
        .nav insert {} end -id $chanid -text $chanid -open True -tag [concat $tag $tags]
    } else {
        .nav insert $serverid end -id $chanid -text $name -tag [concat $tag $tags]
    }
    sorttreechildren .nav $serverid
}

proc connect {serverid} {
    set host [dict get $::config $serverid -host]
    set port [dict get $::config $serverid -port]
    addchantext $serverid "*" "Connecting to $serverid ($host:$port)...\n" italic
    if [dict get $::config $serverid -ssl] {
        set fd [tls::socket $host $port]
    } else {
        set fd [socket $host $port]
    }
    fileevent $fd writable [list connected $fd]
    fileevent $fd readable [list recv $fd]
    dict set ::servers $fd $serverid
    dict set ::serverinfo $serverid [dict create fd $fd nick [dict get $::config $serverid -nick]]
}

proc send {serverid str} {set fd [dict get $::serverinfo $serverid fd]; puts $fd $str; flush $fd}

proc connected {fd} {
    fileevent $fd writable {}
    set serverid [dict get $::servers $fd]
    .nav tag remove disabled $serverid
    addchantext $serverid "*" "Connected.\n" italic
    if {[dict exists $::config $serverid -pass]} {
        send $serverid "PASS [dict get $::config $serverid -pass]"
    }
    send $serverid "NICK [dict get $::config $serverid -nick]"
    send $serverid "USER [dict get $::config $serverid -user] 0 * :Irken user"
}

proc disconnected {fd} {
    set serverid [dict get $::servers $fd]
    fileevent $fd writable {}
    fileevent $fd readable {}

    .nav tag add disabled $serverid
    addchantext $serverid "*" "Disconnected.\n" italic
}

hook append handle001 irken {serverid msg} {
    foreach chan [dict get $::config $serverid -autojoin] {
        ensurechan [chanid $serverid $chan] disabled
        send $serverid "JOIN $chan"
    }
}
hook append handle331 irken {serverid msg} {
    set chanid [chanid $serverid [lindex [dict get $msg args] 0]]
    setchantopic $chanid ""
    addchantext $chanid "*" "No channel topic set.\n" italic
}
hook append handle332 irken {serverid msg} {
    set chanid [chanid $serverid [lindex [dict get $msg args] 0]]
    set topic [dict get $msg trailing]
    setchantopic $chanid $topic
    if {$topic ne ""} {
        addchantext $chanid "*" "Channel topic: $topic\n" italic
    } else {
        addchantext $chanid "*" "No channel topic set.\n" italic
    }
}
hook append handle333 irken {serverid msg} {
    set chanid [chanid $serverid [lindex [dict get $msg args] 0]]
    set nick [lindex [dict get $msg args] 1]
    set time [lindex [dict get $msg args] 2]
    addchantext $chanid "*" "Topic set by $nick at [clock format $time].\n" italic
}
hook append handle353 irken {serverid msg} {
    set chanid [chanid $serverid [lindex [dict get $msg args] 1]]
    foreach user [dict get $msg trailing] {
        addchanuser $chanid $user
    }
}
hook append handle366 irken {serverid msg} {}
hook append handle372 irken {serverid msg} {
    addchantext $serverid "*" "[dict get $msg trailing]\n" italic
}
hook append handle376 irken {serverid msg} {}
hook append handleJOIN irken {serverid msg} {
    set chan [lindex [dict get $msg args] 0]
    set chanid [chanid $serverid $chan]
    ensurechan $chanid {}
    addchanuser $chanid [dict get $msg src]
    if {[dict get $::serverinfo $serverid nick] eq [dict get $msg src]} {
        # I joined
        .nav tag remove disabled $chanid
    } else {
        # Someone else joined
        addchantext $chanid "*" "[dict get $msg src] has joined $chan\n" italic
    }
}
hook append handleMODE irken {serverid msg} {
    set target [lindex [dict get $msg args] 0]
    set chanid [chanid $serverid $target]
    set change [lindex [dict get $msg args] 1]
    set msgdest [expr {[ischannel $chanid] ? $chanid:$serverid}]
    if {[lsearch [dict get $msg src] "!"] == -1} {
        addchantext $msgdest "*" "Mode for $target set to [lrange [dict get $msg args] 1 end]\n" italic
    } else {
        addchantext $msgdest "*" "[dict get $msg src] sets mode for $target to [lrange [dict get $msg args] 1 end]\n" italic
    }
    if {[ischannel $chanid]} {
        switch -- $change {
            "-o" {
                # take ops
                set oper [lindex [dict get $msg args] 2]
                remchanuser [chanid $serverid $target] $oper
                addchanuser [chanid $serverid $target] $oper
            }
            "+o" {
                # give ops
                set oper [lindex [dict get $msg args] 2]
                remchanuser [chanid $serverid $target] $oper
                addchanuser [chanid $serverid $target] @$oper
            }
            "-v" {
                # take voice
                set oper [lindex [dict get $msg args] 2]
                remchanuser [chanid $serverid $target] $oper
                addchanuser [chanid $serverid $target] $oper
            }
            "+v" {
                # give voice
                set oper [lindex [dict get $msg args] 2]
                remchanuser [chanid $serverid $target] oper
                addchanuser [chanid $serverid $target] +$oper
            }
        }
    }
}
hook append handlePART irken {serverid msg} {
    set chan [lindex [dict get $msg args] 0]
    set chanid [chanid $serverid $chan]
    remchanuser $chanid [dict get $msg src]
    if {[dict get $::serverinfo $serverid nick] eq [dict get $msg src]} {
        # I parted
        .nav tag add disabled $chanid
    } else {
        # Someone else parted
        addchantext $chanid "*" "[dict get $msg src] has left $chan\n" italic
    }
}
hook append handlePING irken {serverid msg} {send $serverid "PONG :[dict get $msg args]"}
hook append handlePRIVMSG irken {serverid msg} {
    set chan [string trimleft [lindex [dict get $msg args] 0] $::nickprefixes]
    if {$chan eq [dict get $::serverinfo $serverid nick]} {
        # direct message - so chan is source, not target
        set chan [dict get $msg src]
    }
    set text [dict get $msg trailing]
    set chanid [chanid $serverid $chan]
    ensurechan $chanid {}
    set tag ""
    if {[string first [dict get $::serverinfo $serverid nick] $text] != -1} {set tag highlight}
    if [regexp {^\001ACTION (.+)\001} $text -> text] {
        addchantext $chanid "*" "[dict get $msg src] $text\n" $tag
    } else {
        addchantext $chanid [dict get $msg src] "$text\n" $tag
    }
}
hook append handleNOTICE irken {serverid msg} {
    hook call handlePRIVMSG $serverid $msg
}
hook append handleQUIT irken {serverid msg} {
    foreach chanid [lsearch -all -inline -glob [dict keys $::channelinfo] "$serverid/*"] {
        if {[lsearch [dict get $::channelinfo $chanid users] [dict get $msg src]] != -1} {
            remchanuser $chanid [dict get $msg src]
            if {[dict exists $msg trailing]} {
                addchantext $chanid "*" "[dict get $msg src] has quit ([dict get $msg trailing])\n" italic
            } else {
                addchantext $chanid "*" "[dict get $msg src] has quit\n" italic
            }
        }
    }
}
hook append handleTOPIC irken {serverid msg} {
    set chanid [chanid $serverid [lindex [dict get $msg args] 0]]
    set topic [dict get $msg trailing]
    setchantopic $chanid $topic
    addchantext $chanid "*" "[dict get $msg src] sets title to $topic\n" italic
}
hook append handleUnknown irken {serverid msg} {
    addchantext $serverid "*" $line\n
}

proc recv {fd} {
    if [eof $fd] {
        disconnected $fd
        return
    }
    gets $fd line
    set serverid [dict get $::servers $fd]
    set line [string trimright $line]
    if {! [regexp {^(?::([^ !]*)(?:!([^ @]*)(?:@([^ ]*))?)?\s+)?(\S+)\s*([^:]+)?(?::(.*))?} $line -> src user host cmd args trailing]} {
        .t insert end PARSE_ERROR:$line\n warning
        return
    }
    if {$trailing ne ""} {
        lappend args $trailing
    }
    if {[regexp {^\d+$} $cmd]} {
        # Numeric responses specify a useless target afterwards
        set args [lrange $args 1 end]
    }
    set msg [dict create src $src user $user host $host cmd $cmd args $args trailing $trailing]
    set hook handle$cmd
    if {[hook exists $hook ne ""]} {
        hook call $hook $serverid $msg
    } else {
        hook call $hook handleUnknown $serverid $msg
    }
}

hook append cmdSERVER irken {serverid arg} {
    if {! [dict exists $::config $arg]} {
        addchantext $::active "*" "$arg is not a server.\n" {} $::config
        return
    }
    connect $arg
}
hook append cmdME irken {serverid arg} { sendmsg "\001ACTION $arg\001" }
hook append cmdJOIN irken {serverid arg} {
    set chanid [chanid $serverid $arg]
    ensurechan $chanid disabled
    .nav selection set $chanid
    send $serverid "JOIN :$arg"
}
hook append cmdMSG irken {serverid arg} {
    set target [lrange $arg 0 0]
    set text [lrange $arg 1 end]
    send $serverid "PRIVMSG $target :$text"

    set chanid [chanid $serverid $target]
    ensurechan $chanid {}
    .nav selection set $chanid
    addchantext $chanid [dict get $::serverinfo $serverid nick] "$text\n" self
}
hook append cmdEVAL irken {serverid arg} {
    addchantext $::active "*" "$arg -> [eval $arg]\n" italic
}

proc docmd {serverid chan cmd arg} {
    set hook "cmd[string toupper $cmd]"
    if {[hook exists $hook]} {
        hook call $hook $serverid $arg
    } else {
        send $serverid "$cmd $arg"
        return
    }
}

proc sendmsg {serverid chan text} {
    if {![ischannel $::active]} {
        addchantext $::active "*" "This isn't a channel.\n"
        return
    }
    foreach line [split $text \n] {send $serverid "PRIVMSG $chan :$line"}
    if [regexp {^\001ACTION (.+)\001} $text -> text] {
        addchantext $::active "*" "[dict get $::serverinfo $serverid nick] $nick\n" self
    } else {
        addchantext $::active [dict get $::serverinfo $serverid nick] "$text\n" self
    }
    .t yview end
}

proc returnkey {} {
    if {![dict exists $::serverinfo [serverpart $::active]]} {
        addchantext $::active "*" "Server is disconnected.\n"
        return
    }
    set msg [.cmd get]
    dict set ::channelinfo $::active cmdhistory [concat [list $msg] [dict get $::channelinfo $::active cmdhistory]]
    historybreak
    if [regexp {^/(\S+)\s*(.*)} $msg -> cmd msg] {
        docmd [serverpart $::active] [channelpart $::active] [string toupper $cmd] $msg
    } else {
        sendmsg [serverpart $::active] [channelpart $::active] $msg
    }
    .cmd delete 0 end
}

proc setcurrenttopic {} {
    if {![ischannel $::active]} {
        addchantext $::active "*" "This isn't a channel.\n"
        return
    }
    send [serverpart $::active] "TOPIC [channelpart $::active] :[.topic get]"
    focus .cmd
}

# initialize
dict for {serverid serverconf} $::config {
    ensurechan $serverid [list disabled]
    if {[dict get $serverconf -autoconnect]} {
        connect $serverid
    }
}
# select first serverid by default
.nav selection set [lindex $::config 0]
focus .cmd
