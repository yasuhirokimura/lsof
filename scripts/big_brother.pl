#!/usr/bin/perl -w
#+##############################################################################
#                                                                              #
# File: big_brother.pl                                                         #
#                                                                              #
# Description: check the network sockets with lsof to detect new connections   #
#									       #
# Contributed by Lionel Cons <Lionel.Cons@cern.ch>			       #
#                                                                              #
#-##############################################################################

# @(#)big_brother	1.12 08/14/96 Written by Lionel.Cons@cern.ch

# no warranty! use this at your own risks!

#
# init & setup
#
$verbose = 1;
$lsof_opt = "-itcp -iudp -Di -FcLPn -r 5";
$SIG{'HUP'} = \&hangup;
chop($hostname = `/bin/hostname`);
$fq_hostname = (gethostbyname($hostname))[0];

# Set path to lsof.

if (($LSOF = &isexec("../lsof")) eq "") {	# Try .. first
    if (($LSOF = &isexec("lsof")) eq "") {	# Then try . and $PATH
	print "can't execute $LSOF\n"; exit 1
    }
}

#
# spy forever...
#
$| = 1;
die "$LSOF is not executable\n" unless -x $LSOF;
while (1) {
    $lsof_pid = open(PIPE, "$LSOF $lsof_opt 2>&1 |")
	|| die "can't start $LSOF: $!\n";
    print "# ", &timestamp, " $LSOF $lsof_opt, pid=$lsof_pid\n"
	if $verbose;
    print "#COMMAND     PID     USER P NAME\n";
    $printed = $hanguped = $pid = $proto = 0;
    while (<PIPE>) {
	if (/^lsof: PID \d+, /) {
	    # fatal error message?
	    print "*** $_";
	    last;
	} elsif (/^lsof: /) {
	    # warning
	    warn "* $_";
	} elsif (/^p(\d+)$/) {
	    &flush;
	    $pid = $1;
	    $proto = 0;
	} elsif (/^c(.*)$/) {
	    $command = $1;
	} elsif (/^L(.*)$/) {
	    $user = $1;
	} elsif (/^P(.*)$/) {
	    &flush;
	    $proto = $1;
	} elsif (/^n(.*)$/) {
	    $name = $1;
	    # replace local hostname by 'localhost'
	    $name =~ s/\Q$fq_hostname\E/localhost/g;
	    $name =~ s/[0-9hms]+ ago//g;
	} elsif (/^m$/) {
	    &flush;
	    &clean;
	} else {
	    warn "* bad output ignored: $_";
	}
    }
    kill('INT',  $lsof_pid);
    kill('KILL', $lsof_pid);
    close(PIPE);
}

sub hangup {
    $hanguped = 1;
    $SIG{'HUP'} = \&hangup;
}

sub flush {
    return unless $pid && $proto;
    return if &skip;
    $tag = sprintf("%-9s %5d %8s %1s %s", $command, $pid, $user,
		   substr($proto, 0, 1), $name);
    unless (defined($seen{$tag})) {
	print "+$tag\n";
	$printed++;
    }
    $seen{$tag} = 1;
}

sub clean {
    my(@to_delete, $tag);

    if ($hanguped) {
	$hanguped = 0;
	@to_delete = keys(%seen);
	print "# ", &timestamp, " hangup received, rescanning all connections\n"
	    if $verbose;
    } else {
	@to_delete = ();
	foreach $tag (keys(%seen)) {
	    if ($seen{$tag} == 0) {
		# not seen this time: delete it
		push(@to_delete, $tag);
		print "-$tag\n";
		$printed++;
	    } else {
		# seen this time: reset the flag
		$seen{$tag} = 0;
	    }
	}
    }
    grep(delete($seen{$_}), @to_delete);
    if ($printed > 10) {
	print "# ", &timestamp, "\n" if $verbose;
	$printed = 0;
    }
}

sub skip {
    #
    # put stuff here to ignore some connections, for instance:
    #

    # what we get when the socket gets created...
    return(1) if $name eq '*:0';
    return(1) if $name =~ /^localhost:(\d+)$/ && $1 > 1000;
#
# UDP & TCP stuff
#
    #
    # ignore common daemons
    #
    if ($name =~ /^\*:/ && $user eq 'root' && $pid < 300) {
	return(1) if $command =~ /^inetd(\.afs)?$/;
	return(1) if $command =~ /^rpc\.(stat|lock)d$/;
	return(1) if $command eq 'syslogd' && $name eq '*:syslog';
    }
    #
    # forking beasts: portmap, ypbind, inetd
    #
    if ($command eq 'portmap' && $user eq 'daemon') {
	return(1) if $name =~ /^\*:/;
    } elsif ($command eq 'ypbind') {
	return(1) if $name =~ /^\*:\d+$/;
    }
#
# TCP-only stuff
#
    return(0) unless $proto eq 'TCP';
    #
    # outgoing commands: ftp, telnet, r*
    #
    if ($command eq 'ftp') {
	return(1) if $name =~ /:ftp(-data)?$/;
    } elsif ($command eq 'telnet') {
	return(1) if $name =~ /:telnet$/;
    } elsif ($command eq 'remsh') {
	if ($name =~ /:(\d?\d\d\d)->.+:(\d?\d\d\d)$/) {
	    return(1) if $1 < 1024 && $1 > 990 && $2 < 1024 && $2 > 990;
	} elsif ($name =~ /:(\d?\d\d\d)->.+:(shell|ta-rauth)$/) {
	    return(1) if $1 < 1024 && $1 > 990;
	} elsif ($name =~ /^\*:(\d?\d\d\d)$/) {
	    return(1) if $1 < 1024 && $1 > 990;
	}
    }
    return(0);
}

sub timestamp {
    my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst);

    ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    sprintf("%d/%02d/%02d-%02d:%02d:%02d", $year + 1900, $mon+1, $mday,
      $hour, $min, $sec);
}


## isexec($path) -- is $path executable
#
# $path   = absolute or relative path to file to test for executabiity.
#	    Paths that begin with neither '/' nor '.' that arent't found as
#	    simple references are also tested with the path prefixes of the
#	    PATH environment variable.

sub
isexec {
    my ($path) = @_;
    my ($i, @P, $PATH);

    $path =~ s/^\s+|\s+$//g;
    if ($path eq "") { return(""); }
    if (($path =~ m#^[\/\.]#)) {
	if (-x $path) { return($path); }
	return("");
    }
    $PATH = $ENV{PATH};
    @P = split(":", $PATH);
    for ($i = 0; $i <= $#P; $i++) {
	if (-x "$P[$i]/$path") { return("$P[$i]/$path"); }
    }
    return("");
}
