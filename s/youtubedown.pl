#!/usr/bin/perl -w
# Copyright © 2007-2022 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or
# implied warranty.
#
# Given a YouTube, Vimeo, Instagram or Tumblr video URL,
# downloads the corresponding MP4 file.  The name of the file will be derived
# from the title of the video.
#
#  --title "STRING"  Use this as the title instead.
#  --prefix "STRING" Prepend the title with this.
#  --suffix          Append the video ID to each written file name.
#  --out "FILE"      Output to this exact file name, ignoring title, suffix.
#  --progress        Show a textual progress bar for downloads.
#  --bwlimit Nkbps   Throttle download speed.
#  --parallel N      Bypass rate limiting by making N multiple simultaneous
#        connections. Default 30.
#
#  --size            Instead of downloading it all, print video dimensions.
#        This requires "ffmpeg".
#
#  --list            List the underlying URLs of a playlist.
#  --list --list     List IDs and titles of a playlist.
#  --size --size     List the sizes of each video of a playlist.
#
#  --ping            Probe whether video exists and is embeddable.
#
#  --max-size SIZE   Don't download videos larger than the given size, if
#                    possible. Size can be WxH, "1080p", "SD", etc.  For when
#                    you don't really need that "4K" version.
#
#  --no-mux          Only download pre-muxed videos, instead of sometimes
#                    downloading separate audio and video files, then combining
#                    them afterward with "ffmpeg".  If you specify this option,
#                    you probably can't download anything higher resolution
#                    than 720p.
#
#  --webm            Download WebM or AV1 files if those are higher resolution
#                    than MP4.  Off by default because only VLC can play these
#                    newfangled, irritating formats, which ought not exist.
#
#  --webm-transcode  Download WebM or AV1, but convert them to MP4.  Off by
#                    default because it is very slow, however it is the only
#                    way to get 4K MP4s out of Youtube.
#
# Note: if you have ffmpeg < 2.2, upgrade to something less flaky.
#
# For playlists, it will download each video to its own file.
#
# You can also use this as a bookmarklet, so that you can have a toolbar
# button or bookmark that saves the video you are currently watching to
# your desktop. See https://www.jwz.org/hacks/youtubedown.cgi for instructions
# on how to do that.
#
# Created: 25-Apr-2007.

require 5;
use diagnostics;
use strict;
use POSIX;
use IO::Socket;
use IO::Socket::SSL;
use IPC::Open3;
use HTML::Entities;
use Encode;

my $progname0 = $0;
my $progname = $0; $progname =~ s@.*/@@g;
my ($version) = ('$Revision: 1.1914 $' =~ m/\s(\d[.\d]+)\s/s);

# Without this, [:alnum:] doesn't work on non-ASCII.
use locale;
use POSIX qw(locale_h strftime);
setlocale(LC_ALL, "en_US");

my $verbose = 1;
my $append_suffix_p = 0;
my $webm_p = 0;
my $webm_transcode_p = 0;
my $parallel_loads = 30;

my $http_proxy = undef;
my $ffmpeg = 'ffmpeg';

$ENV{PATH} = "/opt/local/bin:$ENV{PATH}";   # for macports ffmpeg

my @video_extensions = ("mp4", "flv", "webm", "av1");


# Anything placed on this list gets unconditionally deleted when this
# script exits, even if abnormally.
#
my %rm_f;
END { rmf(); }

sub rmf() {
  foreach my $f (sort keys %rm_f) {
    print STDERR "$progname: rm $f\n" if ($verbose > 1);
    unlink $f;
  }
  %rm_f = ();
}

sub signal_cleanup($) {
  my ($s) = @_;
  print STDERR "$progname: SIG$s\n" if ($verbose > 1);
  rmf();
  # Propagate the signal and die. This does not cause END to run.
  $SIG{$s} = 'DEFAULT';
  kill ($s, $$);
}

$SIG{TERM} = \&signal_cleanup;  # kill
$SIG{INT}  = \&signal_cleanup;  # shell ^C
$SIG{QUIT} = \&signal_cleanup;  # shell ^|
$SIG{KILL} = \&signal_cleanup;  # nope
$SIG{ABRT} = \&signal_cleanup;
$SIG{HUP}  = \&signal_cleanup;


my $total_retries = 0;
my $noerror = 0;

sub error($) {
  my ($err) = @_;

  utf8::decode ($err);  # Pack multi-byte UTF-8 back into wide chars.

  if ($noerror) {
    die "$err\n";
  } else {
    print STDERR "$progname: $err\n";
    exit 1;
  }
}


# For internal errors.
my $errorI = ("\n" .
              "\n\tPlease report this URL to jwz\@jwz.org!" .
              "\n\tBut make sure you have the latest version first:" .
              "\n\thttps://www.jwz.org/hacks/#youtubedown" .
              "\n" .
              "\n\tIf this error is happening on *all* videos," .
              "\n\tyou can assume that I am already aware of it." .
              "\n" .
              "\n");
my $error_whiteboard = '';  # for signature diagnostics

sub errorI($) {
  my ($err) = @_;
  if ($error_whiteboard) {
    $error_whiteboard =~ s/^/\t/gm;
    $err .= "\n\n" . $error_whiteboard;
    $error_whiteboard = '';
  }
  $err .= $errorI;
  error ($err);
}


sub url_quote($) {
  my ($u) = @_;
  $u =~ s|([^-a-zA-Z0-9.\@/_\r\n])|sprintf("%%%02X", ord($1))|ge;
  return $u;
}

sub url_unquote($) {
  my ($u) = @_;
  $u =~ s/[+]/ /g;
  $u =~ s/%([a-z0-9]{2})/chr(hex($1))/ige;
  return $u;
}

# Converts &, <, >, " and any UTF8 characters to HTML entities.
# Does not convert '.
#
sub html_quote($) {
  my ($s) = @_;
  return HTML::Entities::encode_entities ($s,
    # Exclude "=042 &=046 <=074 >=076
    '^ \t\n\040\041\043-\045\047-\073\075\077-\176');
}

# Convert any HTML entities to Unicode characters.
#
sub html_unquote($) {
  my ($s) = @_;
  return HTML::Entities::decode_entities ($s);
}


sub fmt_size($) {
  my ($size) = @_;
  return "unknown size" unless defined ($size);
  return ($size > 1024*1024 ? sprintf ("%.0f MB", $size/(1024*1024)) :
          $size > 1024      ? sprintf ("%.0f KB", $size/1024) :
          "$size bytes");
}

sub fmt_bps($) {   # bits per sec, not bytes
  my ($bps) = @_;
  return ($bps > 1024*1024 ? sprintf ("%.1f Mbps", $bps/(1024*1024)) :
          $bps > 1024      ? sprintf ("%.1f Kbps", $bps/1024) :
          "$bps bps");
}


my $progress_ticks = 0;
my $progress_time = 0;
my $progress_rubout = '';
my $progress_last = 0;

sub draw_progress($$$) {
  my ($ratio, $bps, $eof) = @_;   # bits per sec, not bytes

  my $cols = 64;
  my $ticks = int($cols * $ratio);
  my $cursep = (!($verbose > 4) &&
                ((($ENV{TERM} || 'dumb') ne 'dumb') ||
                 (($ENV{INSIDE_EMACS} || '') =~ m/comint/)));

  my $now = time();

  return if ($progress_time == $now && !$eof);

  if ($now > $progress_last) {
    $progress_last = $now;
    my $pct = sprintf("%3d%% %s", 100 * $ratio, fmt_bps ($bps || 0));
    $pct =~ s/^  /. /s;
    my $L = length($pct);
    my $OL = length($progress_rubout);
    print STDERR $progress_rubout if ($OL && $cursep);  # erase previous pct
    $progress_rubout = "\b" x $L;
    while ($ticks > $progress_ticks) {
      print STDERR ".";
      $progress_ticks++;
    }
    print STDERR $pct;
    my $L2 = $OL - $L;  # If the current pct is shorter, clear to EOL
    print STDERR ((' ' x $L2) . ("\b" x $L2))
      if ($L2 > 0 && $cursep);
    print STDERR "\n" unless ($cursep);
  }
  print STDERR "\r" . (' ' x ($cols + 4)) . "\r"  # erase line
    if ($eof && $cursep);
  $progress_time = $now;
  $progress_ticks = 0 if ($eof || !$cursep);
  $progress_rubout = '' if ($eof);
  $progress_last = 0 if ($eof);
}



##############################################################################
#
# Reading data from URLs is the heart of the operation, and is surprisingly
# complicated.  Not only do we need to handle proxies and SSL, but we use
# the data in several different ways:
#
#   - Sometimes we want the data returned in memory;
#   - Sometimes we want it to go directly to a file;
#   - Sometimes we only want the first few KB of the document;
#   - We want to resume incomplete downloads using byte range requests;
#
# And now the latest kink,
#
#   - When downloading a large file, we want to load N URLs in parallel,
#     reading different parts of that file, as a way of circumventing
#     Youtube's bandwidth throttling.


# Like sysread() but timesout and return undef if no data received in N secs.
# The buffer argument is a reference, not a string.
#
my $timeout_p = 0;
sub sysread_timeout($$$$) {
  my ($S, $buf, $bufsiz, $timeout) = @_;
  my $read = undef;
  my $err = "$progname: $timeout seconds with no data\n";
  eval {
    local $SIG{ALRM} = sub {
      $timeout_p = 1;
      print STDERR $err if ($verbose);
      die ($err)
    };
    alarm ($timeout);
    $read = sysread ($S, $$buf, $bufsiz);
    alarm (0);
  };
  if ($@) {
    die unless ($@ eq $err);
  }
  return $read;
}


# Using HTTP "Connection: keep-alive" doesn't actually help much, because
# the video segments on the .googlevideo.com URLs explicitly do
# "Connection: close" on us.  Still, this saves 3 or 4 connect() calls,
# which can be not-insignificant latency. It just could be a lot better
# if we could grab all of the segments on the same connection.
#
# I tried pipelining the connect() calls by loading the N+1 socket with
# O_NONBLOCK so the the TCP handshake would happen on N+1 while we were
# still reading from N, but that actually made things slightly slower rather
# than faster, since the connect() calls to Youtube's segment servers are
# actually pretty quick (under 20 milliseconds), and we can't pipeline or
# share the SSL handshaking (that's exactly what-the-fuck keep-alive is for!)
#
my $keepalive_p = 1;
my %keepalive;  # { $hostname => $socket, ... }

my $sysread_timeout = 30;


sub url_split($) {
  my ($url) = @_;
  error ("not an HTTP URL: $url") unless ($url =~ m@^(https?|feed)://@i);
  my ($proto, undef, $host, $path) = split(m@/@, $url, 4);
  $path = "" unless defined ($path);
  $path = "/$path";

  my $port = ($host =~ s@:([^:/]*)$@@gs ? $1 : undef);

  $port = ($proto eq 'https:' ? 443 : 80) unless $port;
  return ($proto, $host, $port, $path);
}


# Open the socket to the remote web server, handling SSL and proxies.
# Returns the socket, and the proxy-adjusted path for the GET request.
#
sub sock_open($) {
  my ($url) = @_;

  my ($proto, $host, $port, $path) = url_split ($url);
  my $oport = $port;
  my $ohost = $host;

  my $S = undef;
  if ($keepalive_p) {
    $S   = $keepalive{"$proto://$host"};
    delete $keepalive{"$proto://$host"};
  }

  if ($S) {
    print STDERR "$progname: reusing connection: $host\n" if ($verbose > 2);

  } elsif (!$http_proxy && $proto eq 'https:') {

    # If we're not using a proxy, do a direct SSL connection.
    #
    # There *should* be no difference between:
    #      IO::Socket::SSL->new (..)
    # and
    #      IO::Socket::INET->new (...)
    #      IO::Socket::SSL->start_SSL (...)
    # but, there is.
    #
    # As of Jun 2020, the former works but the latter results in Youtube
    # responding with "429 Too Many Requests".  So that means that there
    # is some difference in how those two methods set up the connection,
    # and that difference is being detected by Youtube and causing it to
    # limit our connections more highly.  WTF, and WTF.
    #
    $S = IO::Socket::SSL->new (PeerAddr => $host,
                               PeerPort => $port,
                               Proto    => 'tcp',
                               # Ignore certificate errors
                               verify_hostname => 0,
                               SSL_verify_mode => 0,
                               SSL_verifycn_scheme => 'none',
                               # set hostname for SNI
                               SSL_hostname => $ohost,
                              )
      || error ("socket: SSL: $!");

    $S->autoflush(1);

  } else {

    # If we were just using LWP::UserAgent, we wouldn't have to do all of this
    # proxy crap (that library already handles it) but we use byte-ranges,
    # don't always read a URL to completion, and want to display progress bars.
    # LWP::UserAgent doesn't provide easily-usable APIs for that case, so, we
    # hack the TCP connections more-or-less directly.

    if ($http_proxy) {
      (undef, undef, $host, undef) = split(m@/@, $http_proxy, 4);
      $port = ($host =~ s@:([^:/]*)$@@gs ? $1 : undef);

      # RFC7230: Full url "absolute-form" works, but the "origin-form" of
      # a path (e.g. "/foo.txt") hides proxy use when using SSL.
      $path = $url unless ($proto eq 'https:');
    }

    # This is the connection to the proxy (if using one) or the target host.
    #
    $S = IO::Socket::INET->new (PeerAddr => $host,
                                PeerPort => $port,
                                Proto    => 'tcp',
                                Type     => SOCK_STREAM,
                               );
    error ("connect: $host:$port: $!") unless $S;

    # If we are loading https through a proxy, put the proxy into tunnel mode.
    #
    # Note: this fails if the proxy *itself* is on https.  In that case, we
    # would need to bring up SSL on the connection to the proxy, then again
    # on the interior CONNECT stream.
    #
    if ($http_proxy && $proto eq 'https:') {
      my $hd = "CONNECT $ohost:$oport HTTP/1.0\r\n\r\n";
      my @ha = split(/\r?\n/, $hd);

      if ($verbose > 2) {
        print STDERR "  proxy send P $host:$port " . length($hd) ." bytes\n";
        foreach (@ha) { print STDERR "  ==> $_\n"; }
        print STDERR "  ==>\n";
      }
      syswrite ($S, $hd) || error ("syswrite proxy: $url: $!");

      my $bufsiz = 1024;
      my $buf = '';
      $hd = '';

      while (! $hd) {
        if ($buf =~ m/^(.*?)\r?\n\r?\n(.*)$/s) {
          ($hd, $buf) = ($1, $2);
          last;
        }
        my $buf2 = '';
        my $size = sysread_timeout ($S, \$buf2, $bufsiz, $sysread_timeout);
        print STDERR "  proxy read P $size bytes\n"
          if (defined($size) && $verbose > 2);
        last if (!defined($size) || $size <= 0);
        $buf .= $buf2;
      }
      @ha = split (/\r?\n/, $hd);
      if ($verbose > 2) {
        foreach (@ha) { print STDERR "  <== $_\n"; }
        print STDERR "  <==\n";
      }
      my $ha0 = $ha[0] || 'null response';
      error ("HTTP proxy error: $ha0\n")
        unless ($ha[0] =~ m@^HTTP/[0-9.]+ 20\d@si);
    }

    # Some proxies suck, expect bad behavior like sending a body
    $S->flush() || error ("Could not flush proxy socket: $!");

    # Now we have a stream to the target host (which may be proxied or direct).
    # Put that stream into SSL mode if the target host is https.
    #
    if ($proto eq 'https:') {
      IO::Socket::SSL->start_SSL ($S,
                                  # Ignore certificate errors
                                  verify_hostname => 0,
                                  SSL_verify_mode => 0,
                                  SSL_verifycn_scheme => 'none',
                                  # set hostname for SNI
                                  SSL_hostname => $ohost,
                                 )
          || error ("socket: SSL: $!");
    }

    $S->autoflush(1);
  }

  return ($S, $path);
}


sub build_http_req($$$$$$) {
  my ($host, $path, $referer, $start_byte, $max_bytes, $extra_headers) = @_;

  my $user_agent = "$progname/$version";

  # Finally we are in straight HTTP land (but $path may be either "absolute"
  # or "origin" form, as above.)
  # (You'd think this should be HTTP/1.1 since we are using keep-alive,
  # but that breaks things for some reason.)
  #
  my $hdrs = ("GET $path HTTP/1.0\r\n" .
              "Host: $host\r\n" .
              "User-Agent: $user_agent\r\n");

  my @extra_headers = ();
  push @extra_headers, "Referer: $referer" if ($referer);
  push @extra_headers, "Connection: keep-alive" if ($keepalive_p);
  push @extra_headers, @$extra_headers if ($extra_headers);

  # If we're only reading the first N bytes, don't ask for more.
  #
  if ($start_byte || $max_bytes) {
    #
    # 0-0 means return the first byte.
    # 0-1 means return the first two bytes.
    # 0-  is the same as 0-EOF.
    # 1-  is the same as 1-EOF.
    #
    $start_byte = 0 unless defined ($start_byte);
    my $end_byte = ($max_bytes
                    ? $start_byte + $max_bytes - 1
                    : "");
    push @extra_headers, "Range: bytes=$start_byte-$end_byte";
  }

  $hdrs .= join ("\r\n", @extra_headers, '') if (@extra_headers);
  $hdrs .= "\r\n";

  if ($verbose > 3) {
    print STDERR "\n";
    foreach (split('\r?\n', $hdrs)) {
      print STDERR "  ==> $_\n";
    }
  }

  return $hdrs;
}


sub parse_content_range($$$$) {
  my ($url, $head, $start_byte, $max_bytes) = @_;

  # Note that if we requested a byte range, this is the length of the range,
  # not the length of the full document.
  my ($cl) = ($head =~ m@^Content-Length: \s* (\d+) @mix);

  # "An asterisk character ('*') in place of the complete-length
  # indicates that the representation length was unknown when the header
  # field was generated.  ...  A Content-Range field value is invalid if
  # it contains ... a complete-length value less than or equal to its
  # last-byte-pos value."  And yet, Youtube is sometimes returning:
  #
  #   Content-Range: bytes 296960-307199/-2
  #   Content-Length: 10240

  if ($start_byte || $max_bytes) {
    my ($s, $e, $cl2) = ($head =~ m@^Content-Range:
                                    \s* bytes \s+
                                    (\d+) \s* - \s*
                                    (\d+) \s* / \s*
                                    ( \* | -? \d+ ) \s* $@mix);
    if (!defined($cl2)) {
      # Maybe it responded without a Content-Range header because
      # we requested the whole range?
      ($cl2) = ($head =~ m@^Content-Length: \s* (\d+) \s* $@mix);
      if ($cl2) {
        $s = 0;
        $e = $cl2 - 1;
      }
    }

    error ("attempting to resume download failed: $url\n$head")
      unless defined($cl2);
    error ("attempting to resume download failed: wrong start byte: $url")
      unless ($s == $start_byte);

    # We can't work with "*" or "-2".
    $cl2 = undef unless ($cl2 && $cl2 =~ m/^\d+$/);
    # error ("attempting to resume download failed: bogus range-length: $url" .
    #        "\n$head")
    #   unless ($cl2 && $cl2 =~ m/^\d+$/);

    # In byte-ranges mode, Content-Length is the length of the chunk being
    # returned; the document content-length is in the Content-Range header.
    $cl = $cl2;
  }

  my $document_length = $cl;

  $cl = $start_byte + $max_bytes
    if ($cl && $max_bytes && $start_byte + $max_bytes < $cl);

  return ($cl, $document_length);
}


sub bwlimit_throttle($$$$) {
  my ($bwlimit, $start_time, $bytes, $actual_bits_per_sec) = @_;

  # If we're throttling our download speed, and we went over, hang back.
  #
  if ($bwlimit) {
    my $now = time();
    my $tick = 0.1;
    my $paused = 0;
    while (1) {
      last if ($actual_bits_per_sec <= $bwlimit);
      select (undef, undef, undef, $tick);
      $paused += $tick;
      $now = time();
      my $elapsed = $now - $start_time;

      #### It would be better for this to be measured over the last few
      #### seconds, rather than measured from the beginning of the download,
      #### so that a network drop doesn't cause it to try and "catch up".

      $actual_bits_per_sec = $bytes * 8 / ($elapsed <= 0 ? 1 : $elapsed);
      print STDERR "$progname: bwlimit: delay $paused\n" if ($verbose > 5);
    }
  }
}


# Loads the given URL, returns: $http, $head, $body,
# $bytes_read, $content_length, $document_length.
# Does not retry or process redirects.
#
# This is the old, "simpler" (ha!) way that does not do parallel loads
# of different segments of the document.
#
# Both mechanisms are still in use because there's no point in doing
# the parallel-load thing for short documents that are loaded directly
# into memory (like HTML pages).
#
sub get_url_1($;$$$$$$$$) {
  my ($url, $referer, $to_file, $bwlimit, $start_byte, $max_bytes,
      $append_p, $progress_p, $extra_headers) = @_;

  if ($to_file &&
      $to_file ne '-' &&
      $parallel_loads > 1 &&
      !$append_p &&
      $url =~ m@\b(youtube|google)[^./]*\.com/@si) {
    # This is a direct write to a file, so we can use parallel loads.
    return get_url_1_parallel ($url, $referer, $to_file, $bwlimit,
                               $start_byte, $max_bytes, $append_p,
                               $progress_p, $extra_headers);
  }

  my ($proto, $host, $port, $path) = url_split ($url);
  my $S;
  ($S, $path) = sock_open ($url);
  my $oport = $port;
  my $ohost = $host;

  my $hdrs = build_http_req ($ohost, $path, $referer,
                             $start_byte, $max_bytes, $extra_headers);
  syswrite ($S, $hdrs) ||
    error ('syswrite: ' . ($! || 'I/O error') . ": $host");

  # Using max SSL frame sized (16384) chunks improves performance by
  # avoiding SSL frame splitting on sysread() of IO::Socket::SSL.
  my $bufsiz = 16384;
  my $buf = '';

  $bufsiz = int ($bwlimit / 8)
    if ($bwlimit && int($bwlimit / 8) < $bufsiz);

  # Read network buffers until we have the HTTP response line.
  my $http = '';
  while (! $http) {
    if ($buf =~ m/^(.*?)\r?\n(.*)$/s) {
      ($http, $buf) = ($1, $2);
      last;
    }
    my $buf2 = '';
    my $size = sysread_timeout ($S, \$buf2, $bufsiz, $sysread_timeout);
    print STDERR "  read A $size\n" if ($verbose > 5);
    last if (!defined($size) || $size <= 0);
    $buf .= $buf2;
  }

  $http =~ s/[\r\n]+$//s;
  print STDERR "  <== $http\n" if ($verbose > 3);

  # If the URL isn't there, don't write to the file.
  $to_file = undef unless ($http =~ m@^HTTP/[0-9.]+ 20\d@si);

  # Read network buffers until we have the response header block.
  my $head = '';
  while (! $head) {
    if ($buf =~ m/^(.*?)\r?\n\r?\n(.*)$/s) {
      ($head, $buf) = ($1, $2);
      last;
    }
    my $buf2 = '';
    my $size = sysread_timeout ($S, \$buf2, $bufsiz, $sysread_timeout);
    print STDERR "  read B $size\n" if ($verbose > 5);
    last if (!defined($size) || $size <= 0);
    $buf .= $buf2;
  }

  if ($verbose > 3) {
    foreach (split(/\n/, $head)) {
      s/\r$//gs;
      print STDERR "  <== $_\n";
    }
    print STDERR "  <== \n";
  }

  # If it's 302, we're going to just return the Location: header after
  # reading to the end of the body, if any (to retain the keepalive pipeline).
  # Typically 302 responses have Content-Length: 0, but not necessarily?
  # And if it's an error, we don't want to write the error body into the
  # output file.
  #
  my $ok_p = ($http =~ m@^HTTP/[0-9.]+ 20\d@si);
  my ($cl, $document_length) =
    ($ok_p
     ? parse_content_range ($url, $head, $start_byte, $max_bytes)
     : parse_content_range ($url, $head, 0, 0));

  $progress_p = 0 if (($cl || 0) <= 0);

  my $out;

  if ($to_file) {

    # No, don't do this.
    # utf8::encode($to_file);   # Unpack wide chars into multi-byte UTF-8.

    if ($to_file eq '-') {
      open ($out, ">-");
      binmode ($out);
    } elsif (! $ok_p) {
      # Don't touch the output file on error or redirect.
    } elsif ($start_byte) {
      $rm_f{$to_file} = 1;
      open ($out, '>>:raw', $to_file) || error ("append $to_file: $!");
      print STDERR "$progname: open \"$to_file\" @ $start_byte\n"
        if ($verbose > 2);
    } elsif ($append_p) {
      $rm_f{$to_file} = 1;
      open ($out, '>>:raw', $to_file) || error ("append $to_file: $!");
      print STDERR "$progname: append \"$to_file\"\n"
        if ($verbose > 2);
    } else {
      $rm_f{$to_file} = 1;
      open ($out, '>:raw',  $to_file) || error ("open $to_file: $!");
      print STDERR "$progname: open \"$to_file\"\n" if ($verbose > 2);
    }

    # If we're proxying a download, also copy the document's headers.
    #
    if ($to_file eq '-') {

      # Maybe if we nuke the Content-Type, that will stop Safari from
      # opening the file by default.  Answer: nope.
      #  $head =~ s@^(Content-Type:)[^\r\n]+@$1 application/octet-stream@gmi;
      # Ok, maybe if we mark it as an attachment?  Answer: still nope.
      #  $head = "Content-Disposition: attachment\r\n" . $head;

      syswrite ($out, $head . "\n\n") || error ("syswrite stdout: $url: $!");
    }
  }

  my $bytes = 0;
  my $body = '';

  my $start_time = time();
  my $actual_bits_per_sec = 0;

  if (!defined($cl) || $cl > 0) {
    while (1) {
      if ($buf eq '') {

        my $size = sysread_timeout ($S, \$buf, $bufsiz, $sysread_timeout);

        print STDERR "  read C " . ($size || 'undef') .
                     " (" . ($start_byte + $bytes) . ")\n"
          if ($verbose > 5);
        last if (!defined($size) || $size <= 0);
      }

      if ($to_file && ($to_file eq '-' || $ok_p)) {
        my $n = syswrite ($out, $buf);
        error ("file $to_file: $!") if (($n || 0) <= 0);
       #print STDERR "  wrote  $n\n" if ($verbose > 5);
      } else {
        $body .= $buf;
      }

      $bytes += length($buf);
      $buf = '';

      my $now = time();
      my $elapsed = $now - $start_time;
      $actual_bits_per_sec = $bytes * 8 / ($elapsed <= 0 ? 1 : $elapsed);

      draw_progress (($start_byte + $bytes) / $document_length,
                     $actual_bits_per_sec, 0)
        if ($progress_p);

      # If we do a read while at EOF, sometimes Youtube hangs for ~30 seconds
      # before sending back the EOF, so just stop reading as soon as we have
      # reached the Content-Length or $max_bytes. (Oh hey, that's because of
      # keep-alive. Duh.)
      #
      if ($cl && $start_byte + $bytes >= $cl) {
        print STDERR "  EOF (" . ($start_byte + $bytes) . " >= $cl)\n"
          if ($verbose > 5);
        last;
      }

      bwlimit_throttle ($bwlimit, $start_time, $bytes, $actual_bits_per_sec);
    }
  }

  draw_progress (($cl ? ($start_byte + $bytes) / $document_length : 0),
                 $actual_bits_per_sec, 1)
    if ($progress_p &&
        !($max_bytes ||  # don't draw EOF if we're chunking a single URL.
          $start_byte + $bytes >= $document_length));

  if ($to_file && !$ok_p) {
    error ("\"$to_file\" unexpectedly vanished!") unless (-f $to_file);
    print STDERR "$progname: close \"$to_file\"\n" if ($verbose > 2);
    close $out || error ("close $to_file: $!");
  }

  if ($verbose > 3) {
    if ($to_file) {
      print STDERR "  <== [ body ]: $bytes bytes " .
                   ($append_p ? "appended " : "written") .
                   " to file \"$to_file\"\n";
    } else {
      print STDERR "  <== [ body ]: $bytes bytes\n";
      if ($verbose > 4 &&
          $head =~ m@^Content-Type: \s*   # Safe types to dump to stderr
                      ( text/ |
                        application/json |
                        application/x-www- |
                        video/vnd\.mpeg\.dash\.mpd
                      )@mix) {
        foreach (split(/\n/, $body)) {
          s/\r$//gs;
          print STDERR "  <== $_\n";
        }
      }
    }
  }

  if ($keepalive_p &&
      !$timeout_p &&
      $http &&
      $head =~ m/^Connection: keep-alive/mi &&
      $head =~ m/^Content-Length: /mi) {
    print STDERR "$progname: keepalive: $host\n" if ($verbose > 2);
    $keepalive{"$proto://$host"} = $S;
  } else {
    if ($keepalive_p && $verbose > 2) {
      my $why = ($head =~ m/^Connection: close/mi ? 'explicit close' :
                 $head !~ m/^Content-Length:/mi ? 'no length' :
                 !$http ? 'null response' :
                 $timeout_p ? 'timed out' :
                 'implicit close');
      print STDERR "$progname: no keepalive: $why: $host\n";
    }
    delete $keepalive{"$proto://$host"};
    close $S;
  }

  $timeout_p = 0;

  $http = 'HTTP/1.1 500 null response' unless $http;

  # Check to see if a network failure truncated the file and warn.
  # Caller will then resume the download using byte ranges.
  #
  if ($to_file && 
      $cl && 
      $start_byte + $bytes < $cl-1) {
    my $pct = int (100 * ($start_byte + $bytes) / $cl);
    $pct = sprintf ("%.2f", 100 * $bytes / $cl) if ($pct == 100);
    print STDERR "$progname: got only $pct% (" .
                 ($start_byte + $bytes) . " / $cl)" .
                 " of \"$to_file\", resuming...\n"
      if ($verbose > 0);
  }

  if (! ($head =~ m/^Content-Length:/mi)) {
    # Sometimes we don't get a length, but since we already read the data,
    # we can fake it now, for the benefit of --progress.
    $head .= "\nContent-Length: $bytes";
  }

  return ($http, $head, $body, $bytes, $cl, $document_length);
}


# Loads the given URL, processes redirects; retries dropped connections.
# Returns: $http, $head, $body, $final_redirected_url.
#
sub get_url($;$$$$$$$$) {
  my ($url, $referer, $to_file, $bwlimit, $max_bytes, 
      $append_p, $progress_p, $force_ranges_p, $extra_headers) = @_;

  my $orig_url       = $url;
  my $redirect_count = 0;
  my $error_count    = 0;
  my $max_redirects  = 20;
  my $max_errors     = 5;
  my $total_bytes    = 0;
  my $start_byte     = 0;

  errorI ("force_ranges requires output file")
    if ($force_ranges_p && !$to_file);

  do {
    
    $url =~ s/\#.*$//s;  # Remove HTML anchor

    # If $force_ranges_p is true, we always make multiple sub-range requests
    # for a single document instead of reading the whole document in one
    # request. This is because Youtube rate-limits these URLs, but there is
    # a full-speed setup burst at the beginning. Empirically, the burst size
    # seems to be around 16MB. So if we read a 100MB document with a single
    # request, the first 16MB comes in fast, and the remaining 84MB comes in
    # slow. If we make 7 different requests instead of 1, it's way faster
    # even with the extra connect() latency because we get the setup burst
    # on each one.
    #
    # Update, Apr 2019: burst size seems to be 10MB now.
    #
    my $burst_size = 1024*1024*10;

    my $max_bytes_2 = (($force_ranges_p &&
                        (!defined($max_bytes) || $max_bytes > $burst_size))
                       ? $burst_size
                       : $max_bytes);

    print STDERR "$progname: GET $url" .
                 ($max_bytes_2
                  ? " $start_byte-" . ($start_byte + $max_bytes_2)
                  : '') . "\n"
      if ($verbose == 3);

    my ($http, $head, $body, $bytes, $cl, $cl2) =
      get_url_1 ($url, $referer, $to_file, $bwlimit,
                 $start_byte, $max_bytes_2,
                 $append_p, $progress_p, $extra_headers);

    $total_bytes += $bytes;
    $max_bytes -= $bytes if defined($max_bytes);

    my $target_length = ($force_ranges_p ? $cl2 : $cl);

    if ($force_ranges_p && $http =~ m@^HTTP/[0-9.]+ 20\d@si) {
      # We are allowed as many force-ranges retries as necessary.
      $error_count--;
    }

    if ($http =~ m@^HTTP/[0-9.]+ 30[123]@si) {    # Redirects
      my ($location) = ($head =~ m@^Location:[ \t]*([^\r\n]+)@mi);
      if (! $location) {
        $http = 'HTTP/1.1 500 no location header in 30x';
        error ($http);

      } elsif ($location =~ m@\bgoogle\.com/sorry/@s) {
        # Short circuit Youtube's CAPCHA error instead of retrying
        $http = 'HTTP/1.1 403 CAPCHA required: ' . $location;
        error ($http);

      } else {
        print STDERR "$progname: redirect from $url to $location\n"
          if ($verbose > 3);

        $referer = $url;
        $url = $location;

        if ($url =~ m@^/@) {
          $url = "$1$url" if ($referer =~ m@^(https?://[^/]+)@si);
        } elsif (! ($url =~ m@^[a-z]+:@i)) {
          $url = "$1$url" if ($referer =~ m@^(https?:)@si);
        }
      }

      error ("too many redirects ($max_redirects) from $orig_url")
        if ($redirect_count++ > $max_redirects);

    } elsif (! ($http =~ m@^HTTP/[0-9.]+ 20\d@si)) {  # Errors

      if ($body =~ m@([^<>.:]*verify that you are a human[^<>.:]*)@si) {
        # Vimeo: there's no coming back from this, don't retry.
        $max_errors = $error_count+1;
      }

      if ($http =~ m@\b429\b@si) {
        # "Too many requests". There's no coming back from this, don't retry.
        $max_errors = $error_count+1;
      }

      return ($http, $head, $body, $url)  # Return error to caller.
        if (++$error_count >= $max_errors);

      print STDERR "$progname: $http: retrying $url\n"
        if ($verbose > 3);

    } elsif (defined($target_length) && $total_bytes < $target_length) {

      # Did not get all of the bytes we wanted; try to get more using
      # byte-ranges, next time around the loop.

      $start_byte = $total_bytes;
      $append_p = 1;

      $error_count++ if ($bytes <= 0);  # Null response counts as error.

      error ("too many retries ($max_errors) attempting to resume $orig_url")
        if ($error_count++ > $max_errors);
      print STDERR "$progname: got $start_byte of $total_bytes bytes;" .
                   " resuming $url\n"
        if ($verbose > 3);

    } else {
      return ($http, $head, $body, $url); # 100%, or HTTP error.
    }
  } while (1);
}


sub get_url_hdrs($$) {
  my ($url, $hdrs) = @_;
  return get_url ($url, undef,   # $referer
                  undef, # $to_file
                  undef, # $bwlimit
                  undef, # $max_bytes
                  undef, # $append_p
                  undef, # $progress_p
                  undef, # $force_ranges_p
                  $hdrs);
}


sub check_http_status($$$$) {
  my ($id, $url, $http, $err_p) = @_;
  return 1 if ($http =~ m@^HTTP/[0-9.]+ 20\d@si);
  errorI ("$id: $http: $url") if ($err_p > 1 && $verbose > 0);
  error  ("$id: $http: $url") if ($err_p);
  return 0;
}


##############################################################################
#
# This is the new way, that loads different segments of the document in
# parallel.  This is only used for URLs we are downloading to a file,
# not for URLs that are returning in-memory data.

# Returns a qurl (queue url) object, not yet connected.
#
sub qurl_make($$$$$$) {
  my ($url, $seek_byte, $start_byte, $max_bytes, $bwlimit, $filename) = @_;
  my ($proto, $host, $port, $path) = url_split ($url);
  my %qurl = ( 
    id            => 0,
    url           => $url,
    proto         => $proto,
    host          => $host,
    path          => $path,
    seek_byte     => $seek_byte  || 0,
    start_byte    => $start_byte || 0,
    max_bytes     => $max_bytes  || 0,
    bwlimit       => $bwlimit    || 0,
    read_sock     => undef,
    buf           => '',
    http          => '',
    head          => '',
    filename      => $filename,
    write_sock    => undef,
    bytes_written => 0,
    eof           => 0,
    keepalive     => $keepalive_p,
  );
  return \%qurl;
}


# Open the connection and send the GET request.
#
sub qurl_get($;$$$$) {
  my ($qurl, $referer, $start_byte, $max_bytes, $extra_headers) = @_;

  my $user_agent = "$progname/$version";

  {
    my ($sock, $path) = sock_open ($qurl->{url});
    $qurl->{read_sock} = $sock;
    $qurl->{path} = $path;
  }

  my $hdrs = build_http_req ($qurl->{host}, $qurl->{path}, $referer,
                             $start_byte, $max_bytes, $extra_headers);
  syswrite ($qurl->{read_sock}, $hdrs) ||
    error ('syswrite: ' . ($! || 'I/O error') . ": " . $qurl->{host});
}


# Having read a buffer of data, feed it into the qurl.
#
sub qurl_read_chunk($) {
  my ($qurl) = @_;

  # Using max SSL frame sized (16384) chunks improves performance by
  # avoiding SSL frame splitting on sysread() of IO::Socket::SSL.
  my $bufsiz = 16384;

  my $id = $qurl->{id};
  my $bwlimit = $qurl->{bwlimit} || 0;
  $bufsiz = int ($bwlimit / 8)
    if ($bwlimit && int($bwlimit / 8) < $bufsiz);

  if ($qurl->{max_bytes}) {
    my $remaining = $qurl->{max_bytes} - $qurl->{bytes_written};
    $bufsiz = $remaining if ($remaining < $bufsiz);
  }

  if ($bufsiz <= 0) {
    $qurl->{eof} = 1;
  } else {
    my $buf2 = '';
    my $size = sysread_timeout ($qurl->{read_sock}, \$buf2, $bufsiz,
                                $sysread_timeout);
    print STDERR "  $id read $size\n" if ($verbose > 5);
    $qurl->{buf} .= $buf2;
    $qurl->{eof} = 1 if (!defined($size) || $size <= 0);
  }

  # If we don't have an HTTP response line yet, extract it from the buffer.
  #
  if (!$qurl->{http} &&
      $qurl->{buf} =~ m/^(.*?)\r?\n(.*)$/s) {
    ($qurl->{http}, $qurl->{buf}) = ($1, $2);

    $qurl->{http} =~ s/[\r\n]+$//s;
    print STDERR "  <== " . $qurl->{http} . "\n" if ($verbose > 3);

    if (! ($qurl->{http} =~ m@^HTTP/[0-9.]+ 20\d@si)) {
      $qurl->{eof} = 1;
      error ($qurl->{filename} . ": " . $qurl->{http});
    }
  }

  # If we don't have a complete header block yet, extract it from the buffer.
  #
  if (!$qurl->{head} &&
      $qurl->{buf} =~ m/^(.*?)\r?\n\r?\n(.*)$/s) {
    ($qurl->{head}, $qurl->{buf}) = ($1, $2);

    if ($verbose > 3) {
      foreach (split(/\n/, $qurl->{head})) {
        s/\r$//gs;
        print STDERR "  <== $_\n";
      }
      print STDERR "  <== \n";
    }

    if (!$qurl->{eof}) {

      # Touch the file, since +< gets an error if it doesn't exist.
      if (! -f $qurl->{filename}) {
        open (my $fd, '>:raw', $qurl->{filename}) ||
          error ($qurl->{filename} . ": $!");
        close $fd;
      }

      open ($qurl->{write_sock}, '+<:raw', $qurl->{filename}) ||
        error ($qurl->{filename} . ": $!");

      seek ($qurl->{write_sock}, $qurl->{seek_byte}, SEEK_SET) ||
        error ("$id seek: $!");

      print STDERR "$progname: open \"" . $qurl->{filename} . "\"\n"
        if ($verbose > 2);
    }
  }

  if (!$qurl->{eof} && $qurl->{write_sock} && $qurl->{buf}) {
    my $n = syswrite ($qurl->{write_sock}, $qurl->{buf});
    error ("file " . $qurl->{filename} . ": " . ($! || "unknown error"))
      if (($n || 0) <= 0);
    $qurl->{bytes_written} += $n;
    $qurl->{buf} = '';
    print STDERR "  $id wrote $n (" . $qurl->{bytes_written} . ")\n"
      if ($verbose > 5);
  }

  if (!$qurl->{eof} &&
      $qurl->{max_bytes} &&
      $qurl->{bytes_written} >= $qurl->{max_bytes}) {
    $qurl->{eof} = 1;
    print STDERR "  $id done (" . $qurl->{bytes_written} . ")\n"
      if ($verbose > 5);
  }

  if ($qurl->{eof}) {

    if ($qurl->{read_sock}) {
      if ($qurl->{keepalive} &&
          $qurl->{head} =~ m/^Connection: keep-alive/mi &&
          $qurl->{head} =~ m/^Content-Length: /mi &&
          !$keepalive{$qurl->{proto} . '://' . $qurl->{host}}) {
        print STDERR "$progname: $id keepalive: " . $qurl->{host} . "\n"
          if ($verbose > 2);
        $keepalive{$qurl->{proto} . '://' . $qurl->{host}} =
          $qurl->{read_sock};
      } else {
        close ($qurl->{read_sock}) ||
          error ("close " . $qurl->{url} . ": $!");
        $qurl->{read_sock} = undef;
      }
    }

    $qurl->{keepalive} = 0;

    if ($qurl->{write_sock}) {
        close ($qurl->{write_sock}) ||
        error ("close " . $qurl->{filename} . ": $!");
      $qurl->{write_sock} = undef;
    }

  }
}


sub get_url_1_parallel($;$$$$$$$$) {
  my ($url, $referer, $to_file, $bwlimit, $start_byte, $max_bytes,
      $append_p, $progress_p, $extra_headers) = @_;

  my $start_time = time();
  my $actual_bits_per_sec = 0;

  my $timeout = 30;

  $start_byte = 0 unless defined($start_byte);

  unlink ($to_file);

  # Open the connection and send a GET, for the full range.
  # This is how we learn the size of the full document.
  my $qurl0 = qurl_make ($url, 0, $start_byte, $max_bytes, $bwlimit, $to_file);
  qurl_get ($qurl0, $referer, $start_byte, $max_bytes, $extra_headers);

  # Read from the URL until we have gotten the full header response.
  # We may also have ended up reading part of the document body.
  #
  while (!$qurl0->{eof} &&
         !$qurl0->{head} &&
         $timeout > 0) {
    my $rin = my $win = my $ein = '';
    vec($rin, fileno($qurl0->{read_sock}), 1) = 1;
    $ein = $rin | $win;
    my ($nfound, $timeleft) =
      select (my $rout = $rin, my $wout = $win, my $eout = $ein, $timeout);
    $timeout = $timeleft;
    if (vec($rout, fileno($qurl0->{read_sock}), 1)) {
      qurl_read_chunk ($qurl0);
    }
  }

  my ($cl, $document_length) =
    parse_content_range ($url, $qurl0->{head}, $start_byte, $max_bytes);
  error ("no range length: $url") unless $cl;
  error ("no content length: $url") unless $document_length;

  # My first thought was to have a maximum number of bytes for each worker
  # to load, and then start up to N workers to load that; and start more
  # workers once those dropped off.  But I think it makes more sense to just
  # take the document size and divide by the number of workers.
  #
  my $max_workers = $parallel_loads;
  # my $chunksize = 1024 * 1024 * 2;
  my $chunksize = int (($cl / $max_workers) + 1);
  my $min_chunksize = 1024 * 10;
  $chunksize = $min_chunksize if ($chunksize < $min_chunksize);

  my @pending_queue = ();
  my @running_queue = ( $qurl0 );
  my @all_qurls     = ( $qurl0 );

  $max_bytes = $document_length unless $max_bytes;

  # Tell the first chunk to read only $chunksize bytes, even though our GET
  # requested the whole document.  We will terminate early.  Also it may have
  # already read more than that.
  #
  $qurl0->{max_bytes} = ($chunksize > $qurl0->{bytes_written}
                         ? $chunksize
                         : $qurl0->{bytes_written});
  $qurl0->{keepalive} = 0;  # No longer possible with early termination.

  # Enqueue qurls for each subsequent chunk.
  #
  my $i = 1;
  for (my $byte = $start_byte + $qurl0->{max_bytes},
       my $seek = $qurl0->{max_bytes},
       my $ochunk = $chunksize;
       $byte < $start_byte + $max_bytes;
       $byte += $ochunk,
       $seek += $ochunk,
       $ochunk = $chunksize) {
    my $remaining = $max_bytes - $byte;
    my $size = $chunksize;
    $size = $remaining if ($remaining < $size);
    if ($size > 0) {
      my $qurl = qurl_make ($url, $seek, $byte, $size, $bwlimit, $to_file);
      $qurl->{id} = $i;
      push @pending_queue, $qurl;
      push @all_qurls, $qurl;
      print STDERR "$progname: enqueued $i $byte + $size = " .
                   ($byte + $size) . "\n"
        if ($verbose > 3);
      $i++;
    }
  }

  my $bytes = 0;
  while (@pending_queue || @running_queue) {

    # Move from pending to running as the running ones complete.
    #
    while (@pending_queue &&
           @running_queue < $max_workers) {
      my $qurl = shift @pending_queue;
      qurl_get ($qurl, $referer, $qurl->{start_byte}, $qurl->{max_bytes},
                $extra_headers);
      push @running_queue, $qurl;
    }

    # Wait for network data and service each connection.
    #
    my $rin = my $win = my $ein = '';
    foreach my $qurl (@running_queue) {
      vec($rin, fileno($qurl->{read_sock}), 1) = 1;
    }
    $ein = $rin | $win;
    my ($nfound, $timeleft) =
      select (my $rout = $rin, my $wout = $win, my $eout = $ein, $timeout);
    $timeout = $timeleft;
    foreach my $qurl (@running_queue) {
      if (vec($rout, fileno($qurl->{read_sock}), 1)) {
        qurl_read_chunk ($qurl);
      }
    }

    # Remove the finished ones from the running queue, and check for errors.
    #
    my @q2 = ();
    foreach my $qurl (@running_queue) {
      push @q2, $qurl unless ($qurl->{eof});
    }
    @running_queue = @q2;

    # Progress.
    #
    $bytes = 0;
    foreach my $qurl (@all_qurls) {
      $bytes += ($qurl->{bytes_written});
    }

    my $now = time();
    my $elapsed = $now - $start_time;
    $actual_bits_per_sec = $bytes * 8 / ($elapsed <= 0 ? 1 : $elapsed);

    draw_progress (($start_byte + $bytes) / $document_length,
                   $actual_bits_per_sec, 0)
      if ($progress_p);

    bwlimit_throttle ($bwlimit, $start_time, $bytes, $actual_bits_per_sec);
  }

  draw_progress (($cl ? ($start_byte + $bytes) / $document_length : 0),
                 $actual_bits_per_sec, 1)
    if ($progress_p);

  return ($qurl0->{http}, $qurl0->{head}, '', $bytes, $cl, $document_length);
}


##############################################################################


# Runs ffmpeg to determine dimensions of the given video file.
# (We only do this in verbose mode, or with --size.)
#
sub video_file_size($) {
  my ($file) = @_;

  # Sometimes ffmpeg gets stuck in a loop.
  # Don't let it run for more than N CPU-seconds.
  my $limit = "ulimit -t 10";

  my $size = (stat($file))[7];

  my @cmd = ($ffmpeg,
             "-i", $file,
             "-vframes", "0",
             "-f", "null",
             "/dev/null");
  print STDERR "\n$progname: exec: '" . join("' '", @cmd) . "'\n"
    if ($verbose > 3);
  my $result = '';
  {
    my ($in, $out, $err);
    $err = Symbol::gensym;
    my $pid = eval { open3 ($in, $out, $err, @cmd) };

    # If ffmpeg doesn't exist, or dumps core, just ignore it.
    # There's nothing we can do about it anyway.
    if ($pid) {
      close ($in);
      close ($out);
      local $/ = undef;  # read entire file
      while (<$err>) {
        $result .= $_;
      }
      waitpid ($pid, 0);
    }
  }

  print STDERR "\n$result\n" if ($verbose > 3);

  my ($w, $h, $abr) = (0, 0, 0);

  ($w, $h) = ($1, $2)
    if ($result =~ m/^\s*Stream \#.* Video:.* (\d+)x(\d+),? /m);
  $abr = $1
    if ($result =~ m@^\s*Duration:.* bitrate: ([\d.]+ *[kmb/s]+)@m);

  $abr =~ s@/s$@ps@si;

  # I don't understand why ffmpeg will say different things for the
  # complete file, versus for the first 380 KB of the file, e.g.:
  #
  #   Duration: 00:06:41.75, start: 0.000000, bitrate: 7 kb/s
  #   Duration: 00:06:41.75, start: 0.000000, bitrate: 133 kb/s

  return ($w, $h, $size, $abr);
}


sub which($) {
  my ($cmd) = @_;
  return (-x $cmd) if ($cmd =~ m@^/@s);
  foreach my $dir (split (/:/, $ENV{PATH})) {
    my $cmd2 = "$dir/$cmd";
    return $cmd2 if (-x "$cmd2");
  }
  return undef;
}

# When MacOS web browsers download a file, they write metadata into the
# file's extended attributes saying where and when it was downloaded,
# which can be seen in "Get Info" in the Finder.  We do that too, to
# make it easier to figure out the original URL that a video file came
# from.
#
# To extract it:
#
#    xattr -px com.apple.metadata:kMDItemWhereFroms FILE |
#      xxd -r -p | plutil -convert xml1 - -o -
#
# On Linux systems, freedesktop.org proposes "user.xdg.origin.url".
# That's what "curl --xattr" does.  So we write that too.
#
#      xattr -p user.xdg.origin.url FILE
#
sub write_file_metadata_url($$$) {
  my ($file, $id, $url) = @_;

  my $now = time();

  my $xattr = which ("xattr");
  my $plutil = which ("plutil");
  my $mp4tags = which ("mp4tags");   # port install mp4v2

  my $added = 0;
  my $ok = 1;

  if ($xattr) {
    my $date = strftime ('%Y-%m-%dT%H:%M:%SZ', gmtime($now));

    my $plhead = ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" .
                  "<!DOCTYPE plist PUBLIC" .
                  " \"-//Apple//DTD PLIST 1.0//EN\"" .
                  " \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" .
                  "<plist version=\"1.0\">\n");
    my $date_plist = ($plhead .
                      "<array>\n" .
                      "\t<date>$date</date>\n" .
                      "</array>\n" .
                      "</plist>");
    my $url_plist = ($plhead .
                     "<array>\n" .
                      "\t<string>" . html_quote($url) . "</string>\n" .
                      "</array>\n" .
                      "</plist>");

    # Convert the plists to binary form if possible. Probably not strictly
    # necessary.
    #
    if ($plutil) {
      foreach my $s ($date_plist, $url_plist) {
        my ($in, $out, $err);
        $err = Symbol::gensym;
        my $pid = eval { open3 ($in, $out, $err,
                                ($plutil,
                                 '-convert', 'binary1',
                                 '-', '-o', '-')) };
        # If there are errors converting the plist, just ignore them.
        # It's not critical to convert. Though an error would be weird.
        if (!$pid) {
          print STDERR "$progname: $id: $plutil: $!\n";
        } else {
          close ($err);
          syswrite ($in, $s) || error ("$id: $plutil: $!");
          close ($in);

          local $/ = undef;  # read entire file
          my $s2 = '';
          while (<$out>) {
            $s2 .= $_;
          }
          $s = $s2 if $s2;

          waitpid ($pid, 0);
          if ($?) {
            my $exit_value  = $? >> 8;
            my $signal_num  = $? & 127;
            my $dumped_core = $? & 128;
            print STDERR "$progname: $id: $plutil: core dumped!\n"
              if ($dumped_core);
            print STDERR "$progname: $id: $plutil: signal $signal_num!\n"
              if ($signal_num);
            print STDERR "$progname: $id: $plutil: exited with $exit_value!\n"
              if ($exit_value);
          }
        }
      }
    }

    # I suppose setting the quarantine flag is also the proper thing to do.
    #
    my $quarantine = join (';', ('0002',   # downloaded but never opened
                                 sprintf("%08x", $now),
                                 $progname,
                                 "org.jwz.$progname"));

    # Convert the data to hex, to shield nulls from xattr.
    #
    my $hexurl = $url;
    foreach ($date_plist, $url_plist, $quarantine, $hexurl) {
      s/(.)/{ sprintf("%02X ", ord($1)); }/gsex;
    }

    # Now run xattr for each attribute to dump it into the file.
    #
    error ("$file does not exist") unless (-f $file);
    foreach ([$url_plist,  'com.apple.metadata:kMDItemWhereFroms'],
             [$date_plist, 'com.apple.metadata:kMDItemDownloadedDate'],
             [$quarantine, 'com.apple.quarantine'],
             [$hexurl,     'user.xdg.origin.url']) {
      my ($val, $key) = @$_;
      my @cmd = ($xattr, "-w", "-x", $key, $val, $file);
      print STDERR "\n$progname: exec: '" . join("' '", @cmd) . "'\n"
        if ($verbose > 3);
      system (@cmd);
      $added = 1;
      if ($?) {
        $ok = 0;
        my $exit_value  = $? >> 8;
        my $signal_num  = $? & 127;
        my $dumped_core = $? & 128;
        print STDERR "$progname: $id: $cmd[0]: core dumped!\n"
          if ($dumped_core);
        print STDERR "$progname: $id: $cmd[0]: signal $signal_num!\n"
          if ($signal_num);
        print STDERR "$progname: $id: $cmd[0]: exited with $exit_value!\n"
          if ($exit_value);
      }
    }
  } elsif ($verbose > 1) {
    print STDERR "$progname: $id: no metadata: xattr not found on \$PATH\n";
  }


  # If we can, also store the URL inside the file's metadata tags.
  # This shows up in the "Video / Description" field in iTunes
  # rather than in "Info / Comments".
  #
  if ($mp4tags && $file =~ m/\.mp4$/si) {
    my @cmd = ($mp4tags, "-m", $url, $file);
    print STDERR "\n$progname: exec: '" . join("' '", @cmd) . "'\n"
      if ($verbose > 3);

    my ($in, $out, $err);
    $err = Symbol::gensym;
    my $pid = eval { open3 ($in, $out, $err, @cmd) };
    $added = 1;
    if (!$pid) {
      print STDERR "$progname: $id: $cmd[0]: $!\n";
      $ok = 0;
    } else {
      close ($in);
      close ($out);
      close ($err);

      waitpid ($pid, 0);
      if ($?) {
        $ok = 0;
        my $exit_value  = $? >> 8;
        my $signal_num  = $? & 127;
        my $dumped_core = $? & 128;

        if ($verbose > 0) {
          # mp4tags fucks up not-infrequently. Be quieter about it.
          print STDERR "$progname: $id: $cmd[0]: core dumped!\n"
            if ($dumped_core);
          print STDERR "$progname: $id: $cmd[0]: signal $signal_num!\n"
            if ($signal_num);
          print STDERR "$progname: $id: $cmd[0]: exited with $exit_value!\n"
            if ($exit_value);
        }
      }
    }
  }

  print STDERR "$progname: $id: added metadata\n"
    if ($added && $ok && $verbose > 1);
}


# Downloads the first 380 KB of the URL, then runs ffmpeg to
# find out the dimensions of the video.
#
sub video_url_size($$;$$$) {
  my ($id, $url, $ct, $bwlimit, $noerror) = @_;

  my $tmp = $ENV{TMPDIR} || "/tmp";
  my $ext = content_type_ext ($ct || '');
  my $file = sprintf("$tmp/$progname-%08x.$ext", rand(0xFFFFFFFF));

  # Need a lot of data to get size from 1080p.
  #
  # This used to be 320 KB, but I see 640x360 140 MB videos where we can't
  # get the size without 680 KB.
  #
  # And now I see a 624 x 352, 180 MB, 50 minute video that gets
  # "error reading header: -541478725" unless we read 910 KB.
  #
  my $bytes = 1024 * 1024;

  # If it's a segmented URL, only grab data for the first one.
  #
  # But HEAD all of them (really, GET of 1 byte) to total up the
  # final Content-Length; I don't see another way to find that.
  # Sep 2020: No, that takes too long, there might be thousands.
  #
  my $min_segs = 3;
  my $max_segs = 8;
  my $segp = (ref($url) eq 'ARRAY');
  my $size_guess = 0;

  my $size = 0;
  my ($http, $head, $body);
  if ($segp) {
    my $i = 0;
    my $cl = 0;
    my $total = scalar (@$url);
    foreach my $u2 (@$url) {
      my $append_p = ($i > 0);
      my $donep = ($i >= $min_segs);

      ($http, $head, $body) = get_url ($u2, undef, 
                                       ($donep ? undef : $file),
                                       $bwlimit,
                                       ($donep ? 1 : $bytes),
                                       $append_p);

      # internal error if still 403 after retries.
      return () unless check_http_status ($id,
                                          "$url segment $i/$total: $u2",
                                          $http,
                                          ($noerror ? 0 : 2));

      my ($s2) = ($head =~ m@^Content-Range:\s* bytes \s+ [-\d]+ / (\d+) @mix);
         ($s2) = ($head =~ m@^Content-Length: \s* (\d+) @mix)
           unless $s2;
      $size += $s2 if defined($s2);
      last if ($i >= $max_segs);
      $i++;
    }

    # Approximate the total content length by assuming that size of the
    # first N segments are representative of the size of the rest.
    $size_guess = $bytes * (@$url / $i);

  } else {
    ($http, $head, $body) = get_url ($url, undef, $file, $bwlimit, $bytes);
    # internal error if still 403
    return () unless check_http_status ($id, $url, $http, $noerror ? 0 : 2);
  }

  ($ct) = ($head =~ m@^Content-Type:   \s* ( [^\s;]+ ) @mix);
  ($size) = ($head =~ m@^Content-Range:  \s* bytes \s+ [-\d]+ / (\d+) @mix)
    unless $size;
  ($size) = ($head =~ m@^Content-Length: \s* (\d+) @mix)
    unless $size;

  $size = $size_guess if ($size_guess);

  errorI ("$id: expected audio or video, got \"$ct\" in $url")
    if ($ct =~ m/text/i);

  $size = -1 unless defined($size); # WTF?

  my ($w, $h, undef, $abr) = video_file_size ($file);
  if (-f $file) {
    print STDERR "$progname: rm \"$file\"\n" if ($verbose > 1);
    unlink $file;
  }

  return ($w, $h, $size, $abr);
}


# 24-Jun-2013: When use_cipher_signature=True, the signature must be
# translated from lengths ranging from 82 to 88 back down to the
# original, unciphered length of 81 (40.40).
#
# This is not crypto or a hash, just a character-rearrangement cipher.
# Total security through obscurity.  Total dick move.
#
# The implementation of this cipher used by the Youtube HTML5 video
# player lives in a Javascript file with a name like:
#         https://s.ytimg.com/yts/jsbin/html5player-VERSION.js
#   or    https://s.ytimg.com/yts/jsbin/player-VERSION/base.js
# where VERSION changes periodically.  Sometimes the algorithm in the
# Javascript changes, also.  So we name each algorithm according to
# the VERSION string, and dispatch off of that.  Each time Youtube
# rolls out a new html5player file, we will need to update the
# algorithm accordingly.  See guess_cipher(), below.  Run this
# script with --guess if it has changed.  Run --guess --guess from
# cron to have it tell you only when there's a new cipher.
#
# So far, only three commands are used in the ciphers, so we can represent
# them compactly:
#
# - r  = reverse the string;
# - sN = slice from character N to the end;
# - wN = swap 0th and Nth character.
#
# The first number is the "sts" parameter from the html5player file,
# which is the "Signature Time Stamp" corresponding to this algorithm.
# Requesting get_video_info with that number will return URLs using the
# corresponding cipher algorithm. Except sometimes those old 'sts' values
# stop working!  See below.
#
# It used to be that the deciphered signature was always of the form:
# <40-chars, dot, 40-chars>, but that seems to no longer be the case as
# of Nov 2018 or so?
#
my %ciphers = (
# 'vflNzKG7n' => '135957536242 s3 r s2 r s1 r w67',     # 30 Jan 2013
# 'vfllMCQWM' => '136089118952 s2 w46 r w27 s2 w43 s2 r',   # 14 Feb 2013
# 'vflJv8FA8' => '136304655662 s1 w51 w52 r',       # 11 Mar 2013
# 'vflR_cX32' => '1580 s2 w64 s3',          # 11 Apr 2013
# 'vflveGye9' => '1582 w21 w3 s1 r w44 w36 r w41 s1',     # 02 May 2013
# 'vflj7Fxxt' => '1583 r s3 w3 r w17 r w41 r s2',     # 14 May 2013
# 'vfltM3odl' => '1584 w60 s1 w49 r s1 w7 r s2 r',      # 23 May 2013
# 'vflDG7-a-' => '1586 w52 r s3 w21 r s3 r',        # 06 Jun 2013
# 'vfl39KBj1' => '1586 w52 r s3 w21 r s3 r',        # 12 Jun 2013
# 'vflmOfVEX' => '1586 w52 r s3 w21 r s3 r',        # 21 Jun 2013
# 'vflJwJuHJ' => '1588 r s3 w19 r s2',          # 25 Jun 2013
# 'vfl_ymO4Z' => '1588 r s3 w19 r s2',          # 26 Jun 2013
# 'vfl26ng3K' => '15888 r s2 r',          # 08 Jul 2013
# 'vflcaqGO8' => '15897 w24 w53 s2 w31 w4',       # 11 Jul 2013
# 'vflQw-fB4' => '15902 s2 r s3 w9 s3 w43 s3 r w23',      # 16 Jul 2013
# 'vflSAFCP9' => '15904 r s2 w17 w61 r s1 w7 s1',     # 18 Jul 2013
# 'vflART1Nf' => '15908 s3 r w63 s2 r s1',        # 22 Jul 2013
# 'vflLC8JvQ' => '15910 w34 w29 w9 r w39 w24',        # 25 Jul 2013
# 'vflm_D8eE' => '15916 s2 r w39 w55 w49 s3 w56 w2',      # 30 Jul 2013
# 'vflTWC9KW' => '15917 r s2 w65 r',          # 31 Jul 2013
# 'vflRFcHMl' => '15921 s3 w24 r',          # 04 Aug 2013
# 'vflM2EmfJ' => '15920 w10 r s1 w45 s2 r s3 w50 r',      # 06 Aug 2013
# 'vflz8giW0' => '15919 s2 w18 s3',         # 07 Aug 2013
# 'vfl_wGgYV' => '15923 w60 s1 r s1 w9 s3 r s3 r',      # 08 Aug 2013
# 'vfl1HXdPb' => '15926 w52 r w18 r s1 w44 w51 r s1',     # 12 Aug 2013
# 'vflkn6DAl' => '15932 w39 s2 w57 s2 w23 w35 s2',      # 15 Aug 2013
# 'vfl2LOvBh' => '15933 w34 w19 r s1 r s3 w24 r',     # 16 Aug 2013
# 'vfl-bxy_m' => '15936 w48 s3 w37 s2',         # 20 Aug 2013
# 'vflZK4ZYR' => '15938 w19 w68 s1',          # 21 Aug 2013
# 'vflh9ybst' => '15936 w48 s3 w37 s2',         # 21 Aug 2013
# 'vflapUV9V' => '15943 s2 w53 r w59 r s2 w41 s3',      # 27 Aug 2013
# 'vflg0g8PQ' => '15944 w36 s3 r s2',         # 28 Aug 2013
# 'vflHOr_nV' => '15947 w58 r w50 s1 r s1 r w11 s3',      # 30 Aug 2013
# 'vfluy6kdb' => '15953 r w12 w32 r w34 s3 w35 w42 s2',     # 05 Sep 2013
# 'vflkuzxcs' => '15958 w22 w43 s3 r s1 w43',       # 10 Sep 2013
# 'vflGNjMhJ' => '15956 w43 w2 w54 r w8 s1',        # 12 Sep 2013
# 'vfldJ8xgI' => '15964 w11 r w29 s1 r s3',       # 17 Sep 2013
# 'vfl79wBKW' => '15966 s3 r s1 r s3 r s3 w59 s2',      # 19 Sep 2013
# 'vflg3FZfr' => '15969 r s3 w66 w10 w43 s2',       # 24 Sep 2013
# 'vflUKrNpT' => '15973 r s2 r w63 r',          # 25 Sep 2013
# 'vfldWnjUz' => '15976 r s1 w68',          # 30 Sep 2013
# 'vflP7iCEe' => '15981 w7 w37 r s1',         # 03 Oct 2013
# 'vflzVne63' => '15982 w59 s2 r',          # 07 Oct 2013
# 'vflO-N-9M' => '15986 w9 s1 w67 r s3',        # 09 Oct 2013
# 'vflZ4JlpT' => '15988 s3 r s1 r w28 s1',        # 11 Oct 2013
# 'vflDgXSDS' => '15988 s3 r s1 r w28 s1',        # 15 Oct 2013
# 'vflW444Sr' => '15995 r w9 r s1 w51 w27 r s1 r',      # 17 Oct 2013
# 'vflK7RoTQ' => '15996 w44 r w36 r w45',       # 21 Oct 2013
# 'vflKOCFq2' => '16 s1 r w41 r w41 s1 w15',        # 23 Oct 2013
# 'vflcLL31E' => '16 s1 r w41 r w41 s1 w15',        # 28 Oct 2013
# 'vflz9bT3N' => '16 s1 r w41 r w41 s1 w15',        # 31 Oct 2013
# 'vfliZsE79' => '16010 r s3 w49 s3 r w58 s2 r s2',     # 05 Nov 2013
# 'vfljOFtAt' => '16014 r s3 r s1 r w69 r',       # 07 Nov 2013
# 'vflqSl9GX' => '16023 w32 r s2 w65 w26 w45 w24 w40 s2',   # 14 Nov 2013
# 'vflFrKymJ' => '16023 w32 r s2 w65 w26 w45 w24 w40 s2',   # 15 Nov 2013
# 'vflKz4WoM' => '16027 w50 w17 r w7 w65',        # 19 Nov 2013
# 'vflhdWW8S' => '16030 s2 w55 w10 s3 w57 r w25 w41',     # 21 Nov 2013
# 'vfl66X2C5' => '16031 r s2 w34 s2 w39',       # 26 Nov 2013
# 'vflCXG8Sm' => '16031 r s2 w34 s2 w39',       # 02 Dec 2013
# 'vfl_3Uag6' => '16034 w3 w7 r s2 w27 s2 w42 r',     # 04 Dec 2013
# 'vflQdXVwM' => '16047 s1 r w66 s2 r w12',       # 10 Dec 2013
# 'vflCtc3aO' => '16051 s2 r w11 r s3 w28',       # 12 Dec 2013
# 'vflCt6YZX' => '16051 s2 r w11 r s3 w28',       # 17 Dec 2013
# 'vflG49soT' => '16057 w32 r s3 r s1 r w19 w24 s3',      # 18 Dec 2013
# 'vfl4cHApe' => '16059 w25 s1 r s1 w27 w21 s1 w39',      # 06 Jan 2014
# 'vflwMrwdI' => '16058 w3 r w39 r w51 s1 w36 w14',     # 06 Jan 2014
# 'vfl4AMHqP' => '16060 r s1 w1 r w43 r s1 r',        # 09 Jan 2014
# 'vfln8xPyM' => '16080 w36 w14 s1 r s1 w54',       # 10 Jan 2014
# 'vflVSLmnY' => '16081 s3 w56 w10 r s2 r w28 w35',     # 13 Jan 2014
# 'vflkLvpg7' => '16084 w4 s3 w53 s2',          # 15 Jan 2014
# 'vflbxes4n' => '16084 w4 s3 w53 s2',          # 15 Jan 2014
# 'vflmXMtFI' => '16092 w57 s3 w62 w41 s3 r w60 r',     # 23 Jan 2014
# 'vflYDqEW1' => '16094 w24 s1 r s2 w31 w4 w11 r',      # 24 Jan 2014
# 'vflapGX6Q' => '16093 s3 w2 w59 s2 w68 r s3 r s1',      # 28 Jan 2014
# 'vflLCYwkM' => '16093 s3 w2 w59 s2 w68 r s3 r s1',      # 29 Jan 2014
# 'vflcY_8N0' => '16100 s2 w36 s1 r w18 r w19 r',     # 30 Jan 2014
# 'vfl9qWoOL' => '16104 w68 w64 w28 r',         # 03 Feb 2014
# 'vfle-mVwz' => '16103 s3 w7 r s3 r w14 w59 s3 r',     # 04 Feb 2014
# 'vfltdb6U3' => '16106 w61 w5 r s2 w69 s2 r',        # 05 Feb 2014
# 'vflLjFx3B' => '16107 w40 w62 r s2 w21 s3 r w7 s3',     # 10 Feb 2014
# 'vfliqjKfF' => '16107 w40 w62 r s2 w21 s3 r w7 s3',     # 13 Feb 2014
# 'ima-vflxBu-5R' => '16107 w40 w62 r s2 w21 s3 r w7 s3',   # 13 Feb 2014
# 'ima-vflrGwWV9' => '16119 w36 w45 r s2 r',        # 20 Feb 2014
# 'ima-vflCME3y0' => '16128 w8 s2 r w52',       # 27 Feb 2014
# 'ima-vfl1LZyZ5' => '16128 w8 s2 r w52',       # 27 Feb 2014
# 'ima-vfl4_saJa' => '16130 r s1 w19 w9 w57 w38 s3 r s2',   # 01 Mar 2014
# 'ima-en_US-vflP9269H' => '16129 r w63 w37 s3 r w14 r',    # 06 Mar 2014
# 'ima-en_US-vflkClbFb' => '16136 s1 w12 w24 s1 w52 w70 s2',    # 07 Mar 2014
# 'ima-en_US-vflYhChiG' => '16137 w27 r s3',        # 10 Mar 2014
# 'ima-en_US-vflWnCYSF' => '16142 r s1 r s3 w19 r w35 w61 s2',    # 13 Mar 2014
# 'en_US-vflbT9-GA' => '16146 w51 w15 s1 w22 s1 w41 r w43 r',   # 17 Mar 2014
# 'en_US-vflAYBrl7' => '16144 s2 r w39 w43',        # 18 Mar 2014
# 'en_US-vflS1POwl' => '16145 w48 s2 r s1 w4 w35',      # 19 Mar 2014
# 'en_US-vflLMtkhg' => '16149 w30 r w30 w39',       # 20 Mar 2014
# 'en_US-vflbJnZqE' => '16151 w26 s1 w15 w3 w62 w54 w22',   # 24 Mar 2014
# 'en_US-vflgd5txb' => '16151 w26 s1 w15 w3 w62 w54 w22',   # 25 Mar 2014
# 'en_US-vflTm330y' => '16151 w26 s1 w15 w3 w62 w54 w22',   # 26 Mar 2014
# 'en_US-vflnwMARr' => '16156 s3 r w24 s2',       # 27 Mar 2014
# 'en_US-vflTq0XZu' => '16160 r w7 s3 w28 w52 r',     # 31 Mar 2014
# 'en_US-vfl8s5-Vs' => '16158 w26 s1 w14 r s3 w8',      # 01 Apr 2014
# 'en_US-vfl7i9w86' => '16158 w26 s1 w14 r s3 w8',      # 02 Apr 2014
# 'en_US-vflA-1YdP' => '16158 w26 s1 w14 r s3 w8',      # 03 Apr 2014
# 'en_US-vflZwcnOf' => '16164 w46 s2 w29 r s2 w51 w20 s1',    # 07 Apr 2014
# 'en_US-vflFqBlmB' => '16164 w46 s2 w29 r s2 w51 w20 s1',    # 08 Apr 2014
# 'en_US-vflG0UvOo' => '16164 w46 s2 w29 r s2 w51 w20 s1',    # 09 Apr 2014
# 'en_US-vflS6PgfC' => '16170 w40 s2 w40 r w56 w26 r s2',   # 10 Apr 2014
# 'en_US-vfl6Q1v_C' => '16172 w23 r s2 w55 s2',       # 15 Apr 2014
# 'en_US-vflMYwWq8' => '16177 w51 w32 r s1 r s3',     # 17 Apr 2014
# 'en_US-vflGC4r8Z' => '16184 w17 w34 w66 s3',        # 24 Apr 2014
# 'en_US-vflyEvP6v' => '16189 s1 r w26',        # 29 Apr 2014
# 'en_US-vflm397e5' => '16189 s1 r w26',        # 01 May 2014
# 'en_US-vfldK8353' => '16192 r s3 w32',        # 03 May 2014
# 'en_US-vflPTD6yH' => '16196 w59 s1 w66 s3 w10 r w55 w70 s1',    # 06 May 2014
# 'en_US-vfl7KJl0G' => '16196 w59 s1 w66 s3 w10 r w55 w70 s1',    # 07 May 2014
# 'en_US-vflhUwbGZ' => '16200 w49 r w60 s2 w61 s3',     # 12 May 2014
# 'en_US-vflzEDYyE' => '16200 w49 r w60 s2 w61 s3',     # 13 May 2014
# 'en_US-vflimfEzR' => '16205 r s2 w68 w28',        # 15 May 2014
# 'en_US-vfl_nbW1R' => '16206 r w8 r s3',       # 20 May 2014
# 'en_US-vfll7obaF' => '16212 w48 w17 s2',        # 22 May 2014
# 'en_US-vfluBAJ91' => '16216 w13 s1 w39',        # 27 May 2014
# 'en_US-vfldOnicU' => '16217 s2 r w7 w21 r',       # 28 May 2014
# 'en_US-vflbbaSdm' => '16221 w46 r s3 w19 r s2 w15',     # 03 Jun 2014
# 'en_US-vflIpxel5' => '16225 r w16 w35',       # 04 Jun 2014
# 'en_US-vfloyxzv5' => '16232 r w30 s3 r s3 r',       # 11 Jun 2014
# 'en_US-vflmY-xcZ' => '16230 w25 r s1 w49 w52',      # 12 Jun 2014
# 'en_US-vflMVaJmz' => '16236 w12 s3 w56 r s2 r',     # 17 Jun 2014
# 'en_US-vflgt97Vg' => '16240 r s1 r',          # 19 Jun 2014
# 'en_US-vfl19qQQ_' => '16241 s2 w55 s2 r w39 s2 w5 r s3',    # 23 Jun 2014
# 'en_US-vflws3c7_' => '16243 r s1 w52',        # 24 Jun 2014
# 'en_US-vflPqsNqq' => '16243 r s1 w52',        # 25 Jun 2014
# 'en_US-vflycBCEX' => '16247 w12 s1 r s3 w17 s1 w9 r',     # 26 Jun 2014
# 'en_US-vflhZC-Jn' => '16252 w69 w70 s3',        # 01 Jul 2014
# 'en_US-vfl9r3Wpv' => '16255 r s3 w57',        # 07 Jul 2014
# 'en_US-vfl6UPpbU' => '16259 w37 r s1',        # 08 Jul 2014
# 'en_US-vfl_oxbbV' => '16259 w37 r s1',        # 09 Jul 2014
# 'en_US-vflXGBaUN' => '16259 w37 r s1',        # 10 Jul 2014
# 'en_US-vflM1arS5' => '16262 s1 r w42 r s1 w27 r w54',     # 11 Jul 2014
# 'en_US-vfl0Cbn9e' => '16265 w15 w44 r w24 s3 r w2 w50',   # 14 Jul 2014
# 'en_US-vfl5aDZwb' => '16265 w15 w44 r w24 s3 r w2 w50',   # 15 Jul 2014
# 'en_US-vflqZIm5b' => '16268 w1 w32 s1 r s3 r s3 r',     # 17 Jul 2014
# 'en_US-vflBb0OQx' => '16272 w53 r w9 s2 r s1',      # 22 Jul 2014
# 'en_US-vflCGk6yw/html5player' => '16275 s2 w28 w44 w26 w40 w64 r s1', # 24 Jul 2014
# 'en_US-vflNUsYw0/html5player' => '16280 r s3 w7',     # 30 Jul 2014
# 'en_US-vflId8cpZ/html5player' => '16282 w30 w21 w26 s1 r s1 w30 w11 w20', # 31 Jul 2014
# 'en_US-vflEyBLiy/html5player' => '16283 w44 r w15 s2 w40 r s1',  # 01 Aug 2014
# 'en_US-vflHkCS5P/html5player' => '16287 s2 r s3 r w41 s1 r s1 r', # 05 Aug 2014
# 'en_US-vflArxUZc/html5player' => '16289 r w12 r s3 w14 w61 r',  # 07 Aug 2014
# 'en_US-vflCsMU2l/html5player' => '16292 r s2 r w64 s1 r s3',    # 11 Aug 2014
# 'en_US-vflY5yrKt/html5player' => '16294 w8 r s2 w37 s1 w21 s3', # 12 Aug 2014
# 'en_US-vfl4b4S6W/html5player' => '16295 w40 s1 r w40 s3 r w47 r', # 13 Aug 2014
# 'en_US-vflLKRtyE/html5player' => '16298 w5 r s1 r s2 r',    # 18 Aug 2014
# 'en_US-vflrSlC04/html5player' => '16300 w28 w58 w19 r s1 r s1 r', # 19 Aug 2014
# 'en_US-vflC7g_iA/html5player' => '16300 w28 w58 w19 r s1 r s1 r', # 20 Aug 2014
# 'en_US-vfll1XmaE/html5player' => '16303 r w9 w23 w29 w36 s2 r', # 21 Aug 2014
# 'en_US-vflWRK4zF/html5player' => '16307 r w63 r s3',      # 26 Aug 2014
# 'en_US-vflQSzMIW/html5player' => '16309 r s1 w40 w70 s2 w28 s1', # 27 Aug 2014
# 'en_US-vfltYLx8B/html5player' => '16310 s3 w19 w24',      # 29 Aug 2014
# 'en_US-vflWnljfv/html5player' => '16311 s2 w60 s3 w42 r w40 s2 w68 w20', # 02 Sep 2014
# 'en_US-vflDJ-wUY/html5player' => '16316 s2 w18 s2 w68 w15 s1 w45 s1 r', # 04 Sep 2014
# 'en_US-vfllxLx6Z/html5player' => '16309 r s1 w40 w70 s2 w28 s1', # 04 Sep 2014
# 'en_US-vflI3QYI2/html5player' => '16318 s3 w22 r s3 w19 s1 r',   # 08 Sep 2014
# 'en_US-vfl-ZO7j_/html5player' => '16322 s3 w21 s1',      # 09 Sep 2014
# 'en_US-vflWGRWFI/html5player' => '16324 r w27 r s1 r',     # 12 Sep 2014
# 'en_US-vflJkTW89/html5player' => '16328 w12 s1 w67 r w39 w65 s3 r s1', # 15 Sep 2014
# 'en_US-vflB8RV2U/html5player' => '16329 r w26 r w28 w38 r s3',   # 16 Sep 2014
# 'en_US-vflBFNwmh/html5player' => '16329 r w26 r w28 w38 r s3',   # 17 Sep 2014
# 'en_US-vflE7vgXe/html5player' => '16331 w46 w22 r w33 r s3 w18 r s3', # 18 Sep 2014
# 'en_US-vflx8EenD/html5player' => '16334 w8 s3 w45 w46 s2 w29 w25 w56 w2', # 23 Sep 2014
# 'en_US-vflfgwjRj/html5player' => '16336 r s2 w56 r s3',    # 24 Sep 2014
# 'en_US-vfl15y_l6/html5player' => '16334 w8 s3 w45 w46 s2 w29 w25 w56 w2', # 25 Sep 2014
# 'en_US-vflYqHPcx/html5player' => '16341 s3 r w1 r',      # 30 Sep 2014
# 'en_US-vflcoeQIS/html5player' => '16344 s3 r w64 r s3 r w68',    # 01 Oct 2014
# 'en_US-vflz7mN60/html5player' => '16345 s2 w16 w39',       # 02 Oct 2014
# 'en_US-vfl4mDBLZ/html5player' => '16348 r w54 r s2 w49',     # 06 Oct 2014
# 'en_US-vflKzH-7N/html5player' => '16348 r w54 r s2 w49',     # 08 Oct 2014
# 'en_US-vflgoB_xN/html5player' => '16345 s2 w16 w39',       # 09 Oct 2014
# 'en_US-vflPyRPNk/html5player' => '16353 r w34 w9 w56 r s3 r w30', # 12 Oct 2014
# 'en_US-vflG0qgr5/html5player' => '16345 s2 w16 w39',       # 14 Oct 2014
# 'en_US-vflzDhHvc/html5player' => '16358 w26 s1 r w8 w24 w18 r s2 r', # 15 Oct 2014
# 'en_US-vflbeC7Ip/html5player' => '16359 r w21 r s2 r',     # 16 Oct 2014
# 'en_US-vflBaDm_Z/html5player' => '16363 s3 w5 s1 w20 r',     # 20 Oct 2014
# 'en_US-vflr38Js6/html5player' => '16364 w43 s1 r',       # 21 Oct 2014
# 'en_US-vflg1j_O9/html5player' => '16365 s2 r s3 r s3 r w2',    # 22 Oct 2014
# 'en_US-vflPOfApl/html5player' => '16371 s2 w38 r s3 r',    # 28 Oct 2014
# 'en_US-vflMSJ2iW/html5player' => '16366 s2 r w4 w22 s2 r s2',    # 29 Oct 2014
# 'en_US-vflckDNUK/html5player' => '16373 s3 r w66 r s3 w1 w12 r', # 30 Oct 2014
# 'en_US-vflKCJBPS/html5player' => '16374 w15 w2 s1 r s3 r',     # 31 Oct 2014
# 'en_US-vflcF0gLP/html5player' => '16375 s3 w10 s1 r w28 s1 w40 w64 r', # 04 Nov 2014
# 'en_US-vflpRHqKc/html5player' => '16377 w39 r w48 r',      # 05 Nov 2014
# 'en_US-vflbcuqSZ/html5player' => '16379 r s1 w27 s2 w5 w7 w51 r', # 06 Nov 2014
# 'en_US-vflHf2uUU/html5player' => '16379 r s1 w27 s2 w5 w7 w51 r', # 11 Nov 2014
# 'en_US-vfln6g5Eq/html5player' => '16385 w1 r s3 r s2 w10 s3 r',  # 12 Nov 2014
# 'en_US-vflM7pYrM/html5player' => '16387 r s2 r w3 r w11 r',    # 15 Nov 2014
# 'en_US-vflP2rJ1-/html5player' => '16387 r s2 r w3 r w11 r',    # 18 Nov 2014
# 'en_US-vflXs0FWW/html5player' => '16392 w63 s1 r w46 s2 r s3',   # 20 Nov 2014
# 'en_US-vflEhuJxd/html5player' => '16392 w63 s1 r w46 s2 r s3',   # 21 Nov 2014
# 'en_US-vflp3wlqE/html5player' => '16396 w22 s3 r',       # 24 Nov 2014
# 'en_US-vfl5_7-l5/html5player' => '16396 w22 s3 r',       # 25 Nov 2014
# 'en_US-vfljnKokH/html5player' => '16400 s3 w15 s2 w30 w11',    # 26 Nov 2014
# 'en_US-vflIlILAX/html5player' => '16407 r w7 w19 w38 s3 w41 s1 r w1', # 04 Dec 2014
# 'en_US-vflEegqdq/html5player' => '16407 r w7 w19 w38 s3 w41 s1 r w1', # 10 Dec 2014
# 'en_US-vflkOb-do/html5player' => '16407 r w7 w19 w38 s3 w41 s1 r w1', # 11 Dec 2014
# 'en_US-vfllt8pl6/html5player' => '16419 r w17 w33 w53',    # 16 Dec 2014
# 'en_US-vflsXGZP2/html5player' => '16420 s3 w38 s1 w16 r w20 w69 s2 w15', # 18 Dec 2014
# 'en_US-vflw4H1P-/html5player' => '16427 w8 r s1',      # 23 Dec 2014
# 'en_US-vflmgJnmS/html5player' => '16421 s3 w20 r w34 r s1 r',    # 06 Jan 2015
# 'en_US-vfl86Quee/html5player' => '16450 s3 r w25 w29 r w17 s2 r', # 15 Jan 2015
# 'en_US-vfl19kCnd/html5player' => '16444 r w29 s1 r s1 r w4 w28', # 17 Jan 2015
# 'en_US-vflbHLA_P/html5player' => '16451 r w20 r w20 s2 r',     # 20 Jan 2015
# 'en_US-vfl_ZlzZL/html5player' => '16455 w61 r s1 w31 w36 s1',    # 22 Jan 2015
# 'en_US-vflbeV8LH/html5player' => '16455 w61 r s1 w31 w36 s1',    # 26 Jan 2015
# 'en_US-vflhJatih/html5player' => '16462 s2 w44 r s3 w17 s1',     # 28 Jan 2015
# 'en_US-vflvmwLwg/html5player' => '16462 s2 w44 r s3 w17 s1',     # 29 Jan 2015
# 'en_US-vflljBsG4/html5player' => '16462 s2 w44 r s3 w17 s1',     # 02 Feb 2015
# 'en_US-vflT5ziDW/html5player' => '16462 s2 w44 r s3 w17 s1',     # 03 Feb 2015
# 'en_US-vflwImypH/html5player' => '16471 s3 r w23 s2 w29 r w44',  # 05 Feb 2015
# 'en_US-vflQkSGin/html5player' => '16475 w70 r w66 s1 w70 w26 r w48', # 10 Feb 2015
# 'en_US-vflqnkATr/html5player' => '16475 w70 r w66 s1 w70 w26 r w48', # 11 Feb 2015
# 'en_US-vflZvrDTQ/html5player' => '16475 w70 r w66 s1 w70 w26 r w48', # 12 Feb 2015
# 'en_US-vflKjOTVq/html5player' => '16475 w70 r w66 s1 w70 w26 r w48', # 17 Feb 2015
# 'en_US-vfluEf7CP/html5player' => '16475 w70 r w66 s1 w70 w26 r w48', # 18 Feb 2015
# 'en_US-vflF2Mg88/html5player' => '16475 w70 r w66 s1 w70 w26 r w48', # 19 Feb 2015
# 'en_US-vflQTSOsS/html5player' => '16489 s3 r w23 s1 w19 w43 w36',    # 24 Feb 2015
# 'en_US-vflbaqfRh/html5player' => '16489 s3 r w23 s1 w19 w43 w36',    # 25 Feb 2015
# 'en_US-vflcL_htG/html5player' => '16491 w20 s3 w37 r',    # 04 Mar 2015
# 'en_US-vflTbHYa9/html5player' => '16498 s3 w44 s1 r s1 r s3 r s3', # 04 Mar 2015
# 'en_US-vflT9SJ6t/html5player' => '16497 w66 r s3 w60',    # 05 Mar 2015
# 'en_US-vfl6xsolJ/html5player' => '16503 s1 w4 s1 w39 s3 r',   # 10 Mar 2015
# 'en_US-vflA6e-lH/html5player' => '16503 s1 w4 s1 w39 s3 r',   # 13 Mar 2015
# 'en_US-vflu7AB7p/html5player' => '16503 s1 w4 s1 w39 s3 r',   # 16 Mar 2015
# 'en_US-vflQb7e_A/html5player' => '16510 w19 w35 r s2 r s1 w64 s2 w53', # 18 Mar 2015
# 'en_US-vflicH9X6/html5player' => '16510 w19 w35 r s2 r s1 w64 s2 w53', # 20 Mar 2015
# 'en_US-vflvDDxpc/html5player' => '16510 w19 w35 r s2 r s1 w64 s2 w53', # 23 Mar 2015
# 'en_US-vflSp2y2y/html5player' => '16510 w19 w35 r s2 r s1 w64 s2 w53', # 24 Mar 2015
# 'en_US-vflFAPa9H/html5player' => '16510 w19 w35 r s2 r s1 w64 s2 w53', # 25 Mar 2015
# 'en_US-vflImsVHZ/html5player' => '16518 r w1 r w17 s2 r',       # 30 Mar 2015
# 'en_US-vfllLRozy/html5player' => '16518 r w1 r w17 s2 r',       # 31 Mar 2015
# 'en_US-vfldudhuW/html5player' => '16518 r w1 r w17 s2 r',       # 02 Apr 2015
# 'en_US-vfl20EdcH/html5player' => '16511 w12 w18 s1 w60',        # 06 Apr 2015
# 'en_US-vflCiLqoq/html5player' => '16511 w12 w18 s1 w60',        # 07 Apr 2015
# 'en_US-vflOOhwh5/html5player' => '16518 r w1 r w17 s2 r',       # 09 Apr 2015
# 'en_US-vflUPVjIh/html5player' => '16511 w12 w18 s1 w60',        # 09 Apr 2015
# 'en_US-vfleI-biQ/html5player' => '16519 w39 s3 r s1 w36',       # 13 Apr 2015
# 'en_US-vflWLYnud/html5player' => '16538 r w41 w65 w11 r',       # 14 Apr 2015
# 'en_US-vflCbhV8k/html5player' => '16538 r w41 w65 w11 r',       # 15 Apr 2015
# 'en_US-vflXIPlZ4/html5player' => '16538 r w41 w65 w11 r',       # 16 Apr 2015
# 'en_US-vflJ97NhI/html5player' => '16538 r w41 w65 w11 r',       # 20 Apr 2015
# 'en_US-vflV9R5dM/html5player' => '16538 r w41 w65 w11 r',       # 21 Apr 2015
# 'en_US-vflkH_4LI/html5player' => '16546 w13 s1 w4 s2 r s2 w25', # 22 Apr 2015
# 'en_US-vflfy61br/html5player' => '16546 w13 s1 w4 s2 r s2 w25', # 23 Apr 2015
# 'en_US-vfl1r59NI/html5player' => '16548 r w42 s1 r w29 r w2 s2 r',# 28 Apr 2015
# 'en_US-vfl98hSpx/html5player' => '16548 r w42 s1 r w29 r w2 s2 r',# 29 Apr 2015
# 'en_US-vflheTb7D/html5player' => '16554 r s1 w40 s2 r w6 s3 w60',# 30 Apr 2015
# 'en_US-vflnbdC7j/html5player' => '16555 w52 w25 w62 w51 w2 s2 r s1',# 04 May 2015
# 'new-en_US-vfladkLoo/html5player-new' => '16555 w52 w25 w62 w51 w2 s2 r s1',# 05 May 2015
# 'en_US-vflTjpt_4/html5player' => '16560 w14 r s1 w37 w61 r',    # 07 May 2015
# 'en_US-vflN74631/html5player' => '16560 w14 r s1 w37 w61 r',    # 08 May 2015
# 'en_US-vflj7H3a2/html5player' => '16560 w14 r s1 w37 w61 r',    # 12 May 2015
# 'en_US-vflQbG2p4/html5player' => '16560 w14 r s1 w37 w61 r',    # 12 May 2015
# 'en_US-vflHV7Wup/html5player' => '16560 w14 r s1 w37 w61 r',    # 13 May 2015
# 'en_US-vflCbZ69_/html5player' => '16574 w3 s3 w45 r w3 w2 r w13 r',# 20 May 2015
# 'en_US-vflugm_Hi/html5player' => '16574 w3 s3 w45 r w3 w2 r w13 r',# 21 May 2015
# 'en_US-vfl3tSKxJ/html5player' => '16577 w37 s3 w57 r w5 r w13 r',# 26 May 2015
# 'en_US-vflE8_7k0/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 28 May 2015
# 'en_US-vflmxRINy/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 01 Jun 2015
# 'en_US-vflQEtHy6/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 02 Jun 2015
# 'en_US-vflRqg76I/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 03 Jun 2015
# 'en_US-vfloIm75c/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 04 Jun 2015
# 'en_US-vfl0JH6Oo/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 08 Jun 2015
# 'en_US-vflHvL0kQ/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 09 Jun 2015
# 'new-en_US-vflGBorXT/html5player-new' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 10 Jun 2015
# 'en_US-vfl4Y6g4o/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 11 Jun 2015
# 'en_US-vflKAbZ28/html5player' => '16597 s3 r s2',               # 15 Jun 2015
# 'en_US-vflM5YBLT/html5player' => '16602 s2 w25 w14 s1 r',       # 17 Jun 2015
# 'en_US-vflnSSUZV/html5player' => '16603 w20 s2 w11 s3 r s1 w2 w15',# 18 Jun 2015
# 'en_US-vfla1HjWj/html5player' => '16603 w20 s2 w11 s3 r s1 w2 w15',# 22 Jun 2015
# 'en_US-vflPcWTEd/html5player' => '16603 w20 s2 w11 s3 r s1 w2 w15',# 23 Jun 2015
# 'en_US-vfljL8ofl/html5player' => '16609 w29 r s1 r w59 r w45',  # 25 Jun 2015
# 'en_US-vflUXoyA8/html5player' => '16609 w29 r s1 r w59 r w45',  # 29 Jun 2015
# 'en_US-vflzomeEU/html5player' => '16609 w29 r s1 r w59 r w45',  # 30 Jun 2015
# 'en_US-vflihzZsw/html5player' => '16617 s3 r s3 w17',           # 07 Jul 2015
# 'en_US-vfld2QbH7/html5player' => '16623 w58 w46 s1 w9 r w54 s2 r w55',# 08 Jul 2015
# 'en_US-vflVsMRd_/html5player' => '16623 w58 w46 s1 w9 r w54 s2 r w55',# 09 Jul 2015
# 'en_US-vflp6cSzi/html5player' => '16625 w52 w23 s1 r s2 r s2 r',# 16 Jul 2015
# 'en_US-vflr_ZqiK/html5player' => '16625 w52 w23 s1 r s2 r s2 r',# 20 Jul 2015
# 'en_US-vflDv401v/html5player' => '16636 r w68 w58 r w28 w44 r', # 21 Jul 2015
# 'en_US-vflP7pyW6/html5player' => '16636 r w68 w58 r w28 w44 r', # 22 Jul 2015
# 'en_US-vfly-Z1Od/html5player' => '16636 r w68 w58 r w28 w44 r', # 23 Jul 2015
# 'en_US-vflSxbpbe/html5player' => '16636 r w68 w58 r w28 w44 r', # 27 Jul 2015
# 'en_US-vflGx3XCd/html5player' => '16636 r w68 w58 r w28 w44 r', # 29 Jul 2015
# 'new-en_US-vflIgTSdc/html5player-new' => '16648 r s2 r w43 w41 w8 r w67 r',# 03 Aug 2015
# 'new-en_US-vflnk2PHx/html5player-new' => '16651 r w32 s3 r s1 r',# 06 Aug 2015
# 'new-en_US-vflo_te46/html5player-new' => '16652 r s2 w27 s1',   # 06 Aug 2015
# 'new-en_US-vfllZzMNK/html5player-new' => '16657 w11 w29 w63 r w45 w34 s2',# 11 Aug 2015
# 'new-en_US-vflxgfwPf/html5player-new' => '16657 w11 w29 w63 r w45 w34 s2',# 13 Aug 2015
# 'new-en_US-vflTSd4UU/html5player-new' => '16657 w11 w29 w63 r w45 w34 s2',# 14 Aug 2015
# 'new-en_US-vfl2Ys-gC/html5player-new' => '16657 w11 w29 w63 r w45 w34 s2',# 15 Aug 2015
# 'new-en_US-vflRWS2p7/html5player-new' => '16657 w11 w29 w63 r w45 w34 s2',# 19 Aug 2015
# 'new-en_US-vflVBD1Nz/html5player-new' => '16657 w11 w29 w63 r w45 w34 s2',# 20 Aug 2015
# 'new-en_US-vflJVflpM/html5player-new' => '16667 r s1 r w8 r w5 s2 w30 w66',# 24 Aug 2015
# 'en_US-vfleu-UMC/html5player' => '16667 r s1 r w8 r w5 s2 w30 w66',# 26 Aug 2015
# 'new-en_US-vflOWWv0e/html5player-new' => '16667 r s1 r w8 r w5 s2 w30 w66',# 26 Aug 2015
# 'new-en_US-vflyGTTiE/html5player-new' => '16674 w68 s3 w66 s1 r',# 01 Sep 2015
# 'new-en_US-vflCeB3p5/html5player-new' => '16674 w68 s3 w66 s1 r',# 02 Sep 2015
# 'new-en_US-vflhlPTtB/html5player-new' => '16682 w40 s3 w53 w11 s3 r s3 w16 r',# 09 Sep 2015
# 'new-en_US-vflSnomqH/html5player-new' => '16689 w56 w12 r w26 r',# 16 Sep 2015
# 'new-en_US-vflkiOBi0/html5player-new' => '16696 w55 w69 w61 s2 r',# 22 Sep 2015
# 'new-en_US-vflpNjqAo/html5player-new' => '16696 w55 w69 w61 s2 r',# 22 Sep 2015
# 'new-en_US-vflOdTWmK/html5player-new' => '16696 w55 w69 w61 s2 r',# 23 Sep 2015
# 'new-en_US-vfl9jbnCC/html5player-new' => '16703 s1 r w18 w67 r s3 r',# 29 Sep 2015
# 'new-en_US-vflyM0pli/html5player-new' => '16696 w55 w69 w61 s2 r',# 29 Sep 2015
# 'new-en_US-vflJLt_ns/html5player-new' => '16708 w19 s2 r s2 w48 r s2 r',# 30 Sep 2015
# 'new-en_US-vflqLE6s6/html5player-new' => '16708 w19 s2 r s2 w48 r s2 r',# 02 Oct 2015
# 'new-en_US-vflzRMCkZ/html5player-new' => '16711 r s3 r s2 w62 w25 s1 r',# 04 Oct 2015
# 'new-en_US-vflIUNjzZ/html5player-new' => '16711 r s3 r s2 w62 w25 s1 r',# 08 Oct 2015
# 'new-en_US-vflOw5Ej1/html5player-new' => '16711 r s3 r s2 w62 w25 s1 r',# 08 Oct 2015
# 'new-en_US-vflq2mOFv/html5player-new' => '16714 r w37 r w19 r s3 r w5',# 12 Oct 2015
# 'new-en_US-vfl8AWn6F/html5player-new' => '16714 r w37 r w19 r s3 r w5',# 13 Oct 2015
# 'new-en_US-vflEA2BSM/html5player-new' => '16714 r w37 r w19 r s3 r w5',# 14 Oct 2015
# 'new-en_US-vflt2Xpp6/html5player-new' => '16717 r s1 w14',      # 15 Oct 2015
# 'new-en_US-vflDpriqR/html5player-new' => '16714 r w37 r w19 r s3 r w5',# 15 Oct 2015
# 'new-en_US-vflptVjJB/html5player-new' => '16723 s2 r s3 w54 w60 w55 w65',# 21 Oct 2015
# 'new-en_US-vflmR8A04/html5player-new' => '16725 w28 s2 r',      # 23 Oct 2015
# 'new-en_US-vflx6L8FI/html5player-new' => '16735 r s2 r w65 w1 s1',# 27 Oct 2015
# 'new-en_US-vflYZP7XE/html5player-new' => '16734 s1 r s1 w56 w46 s2 r',# 27 Oct 2015
# 'new-en_US-vflQZZsER/html5player-new' => '16734 s1 r s1 w56 w46 s2 r',# 29 Oct 2015
# 'new-en_US-vflsLAYSi/html5player-new' => '16734 s1 r s1 w56 w46 s2 r',# 29 Oct 2015
# 'new-en_US-vflZWDr6u/html5player-new' => '16734 s1 r s1 w56 w46 s2 r',# 02 Nov 2015
# 'new-en_US-vflJoRj2J/html5player-new' => '16742 w69 w47 r s1 r s1 r w43 s2',# 03 Nov 2015
# 'new-en_US-vflFSFCN-/html5player-new' => '16734 s1 r s1 w56 w46 s2 r',# 04 Nov 2015
# 'new-en_US-vfl6mEKMp/html5player-new' => '16734 s1 r s1 w56 w46 s2 r',# 05 Nov 2015
#'player-en_US-vflJENbn4/base' => '16748 s1 w31 r',              # 12 Nov 2015
#  'player-en_US-vfltBCT02/base' => '16756 r s2 r w18 w62 w45 s1', # 17 Nov 2015
# 'player-en_US-vfl0w9xAB/base' => '16756 r s2 r w18 w62 w45 s1', # 17 Nov 2015
# 'player-en_US-vflCIicNM/base' => '16759 w2 s3 r w38 w21 w58',   # 20 Nov 2015
# 'player-en_US-vflUpjAy9/base' => '16758 w26 s3 r s3 r s3 w61 s3 r',# 23 Nov 2015
# 'player-en_US-vflFEzfy7/base' => '16758 w26 s3 r s3 r s3 w61 s3 r',# 24 Nov 2015
# 'player-en_US-vfl_RJZIW/base' => '16770 w3 w2 s3 w39 s2 r s2',  # 01 Dec 2015
# 'player-en_US-vfln_PDe6/base' => '16770 w3 w2 s3 w39 s2 r s2',  # 03 Dec 2015
# 'player-en_US-vflx9OkTA/base' => '16772 s2 w50 r w15 w66 s3',   # 07 Dec 2015
# 'player-en_US-vflPRjCOu/base' => '16776 r s1 r w31 s1',         # 08 Dec 2015
# 'player-en_US-vflOIF62G/base' => '16776 r s1 r w31 s1',         # 10 Dec 2015
# 'player-en_US-vfl2sXoyn/base' => '16777 w13 r s3 w2 r s3 w36',  # 10 Dec 2015
# 'player-en_US-vflF6iOW5/base' => '16777 w13 r s3 w2 r s3 w36',  # 11 Dec 2015
# 'player-en_US-vfl_a6AWr/base' => '16777 w13 r s3 w2 r s3 w36',  # 14 Dec 2015
# 'player-en_US-vflpPblA7/base' => '16777 w13 r s3 w2 r s3 w36',  # 15 Dec 2015
# 'player-en_US-vflktcH0f/base' => '16777 w13 r s3 w2 r s3 w36',  # 16 Dec 2015
# 'player-en_US-vflXJM_5_/base' => '16777 w13 r s3 w2 r s3 w36',  # 17 Dec 2015
# 'player-en_US-vflrSqbyh/base' => '16777 w13 r s3 w2 r s3 w36',  # 20 Dec 2015
# 'player-en_US-vflnrstgx/base' => '16777 w13 r s3 w2 r s3 w36',  # 22 Dec 2015
# 'player-en_US-vflbZPqYk/base' => '16804 r w50 w8 s2 w40 w64 s1',# 05 Jan 2016
# 'player-en_US-vfl2TFPXm/base' => '16804 r w50 w8 s2 w40 w64 s1',# 06 Jan 2016
# 'player-en_US-vflra1XvP/base' => '16806 s1 r w65 s3 r',         # 07 Jan 2016
# 'player-en_US-vfljksafM/base' => '16806 s1 r w65 s3 r',         # 11 Jan 2016
# 'player-en_US-vfl844Wcq/base' => '16806 s1 r w65 s3 r',         # 12 Jan 2016
# 'player-en_US-vflGR-A-c/base' => '16806 s1 r w65 s3 r',         # 14 Jan 2016
# 'player-en_US-vflIfVKII/base' => '16816 s2 w66 r',              # 19 Jan 2016
# 'player-en_US-vfl1SLb2X/base' => '16819 s3 r w29 s1 r s1 w54 r w48',# 20 Jan 2016
# 'player-en_US-vfl7CQfyl/base' => '16819 s3 r w29 s1 r s1 w54 r w48',# 22 Jan 2016
# 'player-en_US-vfl0zK-iw/base' => '16819 s3 r w29 s1 r s1 w54 r w48',# 22 Jan 2016
# 'player-en_US-vfl4ZhWmu/base' => '16825 w12 s1 w47 s2 r s1',    # 26 Jan 2016
# 'player-en_US-vflYjf147/base' => '16826 s1 r s2 r w50 r',       # 27 Jan 2016
# 'player-en_US-vfl66BZ3R/base' => '16826 s1 r s2 r w50 r',       # 28 Jan 2016
# 'player-en_US-vflpwz3pO/base' => '16828 w60 w36 w43 r',         # 01 Feb 2016
# 'player-en_US-vflwvK3-x/base' => '16832 r w67 w1 r s1 w17',     # 03 Feb 2016
# 'player-en_US-vfl93P520/base' => '16832 r w67 w1 r s1 w17',     # 04 Feb 2016
# 'player-en_US-vflj1re2B/base' => '16835 s1 r s3 w69 r s3 w53',  # 08 Feb 2016
# 'player-en_US-vflpN2vEY/base' => '16836 w16 r s3 r',            # 10 Feb 2016
# 'player-en_US-vflCdE8nM/base' => '16841 r w51 s3 r s3 w6 w24 r w21',# 11 Feb 2016
# 'player-en_US-vfl329t6E/base' => '16846 s3 w27 r s2 w29 s2 r s3',# 16 Feb 2016
# 'player-en_US-vflGk0Qy7/base' => '16846 s3 w27 r s2 w29 s2 r s3',# 17 Feb 2016
# 'player-en_US-vfligMRZC/base' => '16849 w4 w3 r w50 r s1 w20 s1',# 18 Feb 2016
# 'player-en_US-vfldIygzk/base' => '16850 w48 r s1 r',            # 20 Feb 2016
# 'player-en_US-vflksMPCE/base' => '16853 s2 w61 s2',             # 23 Feb 2016
# 'player-en_US-vflEGP5iK/base' => '16849 w4 w3 r w50 r s1 w20 s1',# 23 Feb 2016
# 'player-en_US-vflRVQlNU/base' => '16856 w44 w49 r',             # 25 Feb 2016
# 'player-en_US-vflKlzoBL/base' => '16855 w54 r s1 w52 s3 r w16 r',# 28 Feb 2016
# 'player-en_US-vfl_cdzrt/base' => '16855 w54 r s1 w52 s3 r w16 r',# 01 Mar 2016
# 'player-en_US-vflteKQR7/base' => '16861 r w40 s2',              # 04 Mar 2016
# 'player-en_US-vfltwl-FJ/base' => '16864 w42 r w14 s3 r s1 r s2',# 08 Mar 2016
# 'player-en_US-vfl6PWeOD/base' => '16864 w42 r w14 s3 r s1 r s2',# 10 Mar 2016
# 'player-en_US-vflcZVscy/base' => '16873 s1 w55 w32 w39 r s3 r w66 s3',# 14 Mar 2016
# 'player-en_US-vflXE5o5C/base' => '16873 s1 w55 w32 w39 r s3 r w66 s3',# 15 Mar 2016
# 'player-en_US-vfl1858es/base' => '16873 s1 w55 w32 w39 r s3 r w66 s3',# 16 Mar 2016
# 'player-en_US-vflKkAVgb/base' => '16873 s1 w55 w32 w39 r s3 r w66 s3',# 17 Mar 2016
# 'player-en_US-vflpmpoFG/base' => '16881 r w70 s2 w53 s1',       # 22 Mar 2016
# 'player-en_US-vfl1uoDql/base' => '16881 r w70 s2 w53 s1',       # 24 Mar 2016
# 'player-en_US-vfl9rzyi6/base' => '16884 w19 w32 w47 w41 w3 w56 r',# 29 Mar 2016
# 'player-en_US-vflEHWF5a/base' => '16884 w19 w32 w47 w41 w3 w56 r',# 31 Mar 2016
# 'player-en_US-vfl6tDF0R/base' => '16890 s3 r w31 w23 w29',      # 31 Mar 2016
# 'player-en_US-vfljAl26P/base' => '16890 s3 r w31 w23 w29',      # 01 Apr 2016
# 'player-en_US-vfl9xTY8I/base' => '16892 s1 r s3 w37 w43 w20',   # 04 Apr 2016
# 'player-en_US-vfls3wurZ/base' => '16892 s1 r s3 w37 w43 w20',   # 05 Apr 2016
# 'player-en_US-vfli5QvRo/base' => '16892 s1 r s3 w37 w43 w20',   # 06 Apr 2016
# 'player-en_US-vfllNvdW4/base' => '16897 r w4 s2 w41 r w52 r',   # 07 Apr 2016
# 'player-en_US-vfll2CKBY/base' => '16898 w19 r s3',              # 12 Apr 2016
# 'player-en_US-vflELI9Sd/base' => '16903 s3 w53 s2 w2',          # 13 Apr 2016
# 'player-en_US-vflg4mKgv/base' => '16903 s3 w53 s2 w2',          # 14 Apr 2016
# 'player-en_US-vflHZ7KXs/base' => '16903 s3 w53 s2 w2',          # 19 Apr 2016
# 'player-en_US-vflnFj56r/base' => '16903 s3 w53 s2 w2',          # 20 Apr 2016
# 'player-en_US-vfljFzcWO/base' => '16913 w7 r w13 w69 s3 r w14', # 22 Apr 2016
# 'player-en_US-vflQ6YtHH/base' => '16913 w7 r w13 w69 s3 r w14', # 22 Apr 2016
# 'player-en_US-vflvBNQyW/base' => '16912 s3 w7 w24 s1',          # 25 Apr 2016
# 'player-en_US-vflG0wokn/base' => '16916 w62 r w38 s1 r s2 r w13 w12',# 26 Apr 2016
# 'player-en_US-vfll6dEHf/base' => '16916 w62 r w38 s1 r s2 r w13 w12',# 27 Apr 2016
# 'player-en_US-vflA_6ZRP/base' => '16918 w14 s1 r w10',          # 29 Apr 2016
# 'player-en_US-vflL5aRF-/base' => '16920 w42 r s1 r w30 r s2',   # 02 May 2016
# 'player-en_US-vflKklr93/base' => '16920 w42 r s1 r w30 r s2',   # 04 May 2016
# 'player-en_US-vflYi-PAF/base' => '16926 w58 r s3',              # 09 May 2016
# 'player-en_US-vflPykJ0g/base' => '16926 w58 r s3',              # 10 May 2016
# 'player-en_US-vflw9bxTw/base' => '16926 w58 r s3',              # 11 May 2016
# 'player-en_US-vflGdEImZ/base' => '16932 w69 w26 r w8 w22 s1',   # 12 May 2016
# 'player-en_US-vflTZ3kuV/base' => '16932 w69 w26 r w8 w22 s1',   # 19 May 2016
# 'player-en_US-vfl5u7dIk/base' => '16932 w69 w26 r w8 w22 s1',   # 19 May 2016
# 'player-en_US-vflGaNMBw/base' => '16932 w69 w26 r w8 w22 s1',   # 21 May 2016
# 'player-en_US-vfl6uEgGV/base' => '16941 r w36 s1 r w26 s1 w60', # 23 May 2016
# 'player-en_US-vflKZdm1L/base' => '16944 w25 s2 r',              # 24 May 2016
# 'player-en_US-vflNStq7e/base' => '16944 w25 s2 r',              # 25 May 2016
# 'player-en_US-vflAwQJsE/base' => '16945 w53 r w19 s3 w37',      # 31 May 2016
# 'player-en_US-vfl7FG-3v/base' => '16944 w25 s2 r',              # 02 Jun 2016
# 'player-en_US-vfl7vBziO/base' => '16944 w25 s2 r',              # 02 Jun 2016
# 'player-en_US-vflrmwhUy/base' => '16944 w25 s2 r',              # 04 Jun 2016
# 'player-en_US-vfljqy_st/base' => '16958 s3 w46 w64 w67 s2 r',   # 07 Jun 2016
# 'player-en_US-vflzxAejD/base' => '16959 s1 r w4 w67 s3 r w55 r s3',# 08 Jun 2016
# 'player-en_US-vflqpURrL/base' => '16960 r w65 r',               # 09 Jun 2016
# 'player-en_US-vflcUEb1U/base' => '16962 w54 s1 r w9 s1',        # 11 Jun 2016
# 'player-en_US-vflBUz8b9/base' => '16965 w1 r s2 w27',           # 13 Jun 2016
# 'player-en_US-vfl9bYNJa/base' => '16961 s1 r s1 r w35 r',       # 14 Jun 2016
# 'player-en_US-vflruV5iG/base' => '16966 w36 s2 w65 r s2 w11 w31',# 15 Jun 2016
# 'player-en_US-vfldefdPl/base' => '16961 s1 r s1 r w35 r',       # 15 Jun 2016
# 'player-en_US-vfl-nPja1/base' => '16968 w21 s1 w60 s2',         # 20 Jun 2016
# 'player-en_US-vflLyLvKU/base' => '16974 r w45 r',               # 23 Jun 2016
# 'player-en_US-vfl0Cqdyd/base' => '16976 w57 r w57 w38 s3 w47 s2',# 27 Jun 2016
# 'player-en_US-vflOfyD_m/base' => '16976 w57 r w57 w38 s3 w47 s2',# 28 Jun 2016
# 'player-en_US-vflAbrXV8/base' => '16976 w57 r w57 w38 s3 w47 s2',# 30 Jun 2016
# 'player-en_US-vflYIVfbT/base' => '16976 w57 r w57 w38 s3 w47 s2',# 05 Jul 2016
# 'player-en_US-vflL1__zc/base' => '16989 s3 r w58 w34 r',        # 07 Jul 2016
# 'player-en_US-vflH9xME5/base' => '16989 s3 r w58 w34 r',        # 12 Jul 2016
# 'player-en_US-vflxUWFRm/base' => '16989 s3 r w58 w34 r',        # 13 Jul 2016
# 'player-en_US-vflWoKF7f/base' => '16996 r w58 w62 s1 w62 r',    # 14 Jul 2016
# 'player-en_US-vflbQww0A/base' => '16989 s3 r w58 w34 r',        # 17 Jul 2016
# 'player-en_US-vflIl4-ZN/base' => '16989 s3 r w58 w34 r',        # 19 Jul 2016
# 'player-en_US-vfl5RxDNb/base' => '17001 s1 w17 r s3',           # 20 Jul 2016
# 'player-en_US-vflIB5TLK/base' => '16989 s3 r w58 w34 r',        # 21 Jul 2016
# 'player-en_US-vflVo2R8O/base' => '17007 s1 r w35 r s1 r w36 s3',# 27 Jul 2016
# 'player-en_US-vfld7sVQ3/base' => '17007 s1 r w35 r s1 r w36 s3',# 28 Jul 2016
# 'player-en_US-vflua32tg/base' => '17011 w17 s3 r s3 w26 r w19 s2 w8',# 03 Aug 2016
# 'player-en_US-vflHuW2fm/base' => '17011 w17 s3 r s3 w26 r w19 s2 w8',# 04 Aug 2016
# 'player-en_US-vflI2is8G/base' => '17015 w22 r s2 w24 s2 r',     # 08 Aug 2016
# 'player-en_US-vflxMAwM7/base' => '17015 w22 r s2 w24 s2 r',     # 09 Aug 2016
# 'player-en_US-vflD53teA/base' => '17015 w22 r s2 w24 s2 r',     # 12 Aug 2016
# 'player-en_US-vflduS31F/base' => '17015 w22 r s2 w24 s2 r',     # 13 Aug 2016
# 'player-en_US-vflCWknvV/base' => '17015 w22 r s2 w24 s2 r',     # 14 Aug 2016
# 'player-en_US-vflsfFMeN/base' => '17015 w22 r s2 w24 s2 r',     # 16 Aug 2016
# 'player-en_US-vflYm48JC/base' => '17029 s3 w50 r w46 w5 s2',    # 17 Aug 2016
# 'player-en_US-vfl9QlUdu/base' => '17030 r s2 w17 r w1 s1',      # 18 Aug 2016
# 'player-en_US-vflIsoTq9/base' => '17031 r s3 w63 r',            # 22 Aug 2016
# 'player-en_US-vflB4BK_2/base' => '17031 r s3 w63 r',            # 23 Aug 2016
# 'player-en_US-vflrza-6I/base' => '17031 r s3 w63 r',            # 25 Aug 2016
# 'player-en_US-vflCFz7Ac/base' => '17039 s3 w2 s2 w46 s1 w31 w27',# 30 Aug 2016
# 'player-en_US-vflYH10GU/base' => '17039 s3 w2 s2 w46 s1 w31 w27',# 31 Aug 2016
# 'player-en_US-vflqMMQzs/base' => '17039 s3 w2 s2 w46 s1 w31 w27',# 01 Sep 2016
# 'player-en_US-vfl3Us3jU/base' => '17046 s2 r s2 w31 w6 r s2',   # 06 Sep 2016
# 'player-en_US-vfltdrc9Q/base' => '17050 w19 r s1 r s1 w7 r w38 s3',# 07 Sep 2016
# 'player-en_US-vflwEMtjy/base' => '17056 r s3 r w20 s3 r s2 r',  # 13 Sep 2016
# 'player-en_US-vflIb3VDh/base' => '17056 r s3 r w20 s3 r s2 r',  # 14 Sep 2016
# 'player-en_US-vflGe_KH9/base' => '17056 r s3 r w20 s3 r s2 r',  # 15 Sep 2016
# 'player-en_US-vflOrSoUx/base' => '17060 w35 r s3 r w55 s3 w2',  # 20 Sep 2016
# 'player-en_US-vflhmEPlj/base' => '17064 w70 s3 w7 s1 w68 s1 w64',# 21 Sep 2016
# 'player-en_US-vfl-naOSO/base' => '17066 r w30 w40 w48 r s1 w53 s3 r',# 22 Sep 2016
# 'player-en_US-vflHlG7su/base' => '17068 r w35 s2',              # 26 Sep 2016
# 'player-en_US-vfl8j0dbL/base' => '17067 w63 s3 w38 s3 w16 w67 s3 r s1',# 26 Sep 2016
# 'player-en_US-vflw2cgEp/base' => '17067 w63 s3 w38 s3 w16 w67 s3 r s1',# 27 Sep 2016
# 'player-en_US-vflhPhaA1/base' => '17071 w15 s3 r s2 w4 s2 r',   # 28 Sep 2016
# 'player-en_US-vflK2tmSr/base' => '17072 s3 r s3 r w20',         # 29 Sep 2016
# 'player-en_US-vflKBaLr4/base' => '17072 s3 r s3 r w20',         # 30 Sep 2016
# 'player-en_US-vflssZQ6P/base' => '17074 r w9 r s3 r s3 w51 r',  # 03 Oct 2016
# 'player-en_US-vflXU8Lcz/base' => '17079 r w45 s1 r s2 r s2 r w3',# 05 Oct 2016
# 'player-en_US-vflOj6Vz8/base' => '17079 r w45 s1 r s2 r s2 r w3',# 07 Oct 2016
# 'player-en_US-vflQcYs5w/base' => '17079 r w45 s1 r s2 r s2 r w3',# 07 Oct 2016
# 'player-en_US-vfl-E2vny/base' => '17082 r w9 s1 r s1 w66 w30 r w48',# 11 Oct 2016
# 'player-en_US-vflabgyIE/base' => '17086 s2 w6 r s3 w53 r w46 w56',# 12 Oct 2016
# 'player-en_US-vflkqCvzc/base' => '17086 s2 w6 r s3 w53 r w46 w56',# 13 Oct 2016
# 'player-en_US-vflI-HtJG/base' => '17089 w11 w51 r s2 w32 s1',   # 17 Oct 2016
# 'player-en_US-vflMRpBY0/base' => '17092 s1 w68 r w17 w3 s1 w48 r s2',# 18 Oct 2016
# 'player-en_US-vflkGN22k/base' => '17092 s1 w68 r w17 w3 s1 w48 r s2',# 18 Oct 2016
# 'player-en_US-vflEz7zqU/base' => '17093 r s1 w60',              # 21 Oct 2016
# 'player-en_US-vflTBNOIW/base' => '17098 s1 r w37 r s1 w53 r s2 r',# 25 Oct 2016
# 'player-en_US-vflx7_SPL/base' => '17098 s1 r w37 r s1 w53 r s2 r',# 26 Oct 2016
# 'player-en_US-vflvtarAT/base' => '17098 s1 r w37 r s1 w53 r s2 r',# 28 Oct 2016
# 'player-en_US-vflG26Hhi/base' => '17102 w32 w26 s1 r w20',      # 30 Oct 2016
# 'player-en_US-vfliKSBJe/base' => '17104 s1 r s1 r s3 w29 s2 w24',# 30 Oct 2016
# 'player-en_US-vfl9TjB9H/base' => '17105 w8 r w59 w68',          # 01 Nov 2016
# 'player-en_US-vfle0WwUC/base' => '17108 s2 w58 w59',            # 07 Nov 2016
# 'player-en_US-vflcQt09B/base' => '17110 w10 r w29 r w46 r w10 s2',# 07 Nov 2016
# 'player-en_US-vfllAQuZd/base' => '17113 s1 r s3 w44 w63 r',     # 09 Nov 2016
# 'player-en_US-vflgFv_Kx/base' => '17114 s2 w31 s2 r s3 r w60 s2',# 10 Nov 2016
# 'player-en_US-vflZebs2S/base' => '17120 w48 r w8 w28 s2 w22 w61 s2 w59',# 15 Nov 2016
# 'player-en_US-vflSldmkq/base' => '17121 s3 w13 w41 s1 w51 r w53 r w57',# 18 Nov 2016
# 'player-en_US-vflydz95C/base' => '17133 s2 r w59 r s1 w16 s1',  # 29 Nov 2016
# 'player-en_US-vflzQdL0P/base' => '17133 s2 r w59 r s1 w16 s1',  # 01 Dec 2016
# 'player-en_US-vflDkHeWE/base' => '17128 r s3 r w26 s1 r w10',   # 02 Dec 2016
# 'player-en_US-vflr_3iyV/base' => '17135 r w40 s2 r s1 r w61',   # 05 Dec 2016
# 'player-en_US-vflyIX2li/base' => '17141 w58 r s1 w66 r',        # 06 Dec 2016
# 'player-en_US-vfl8r3fjW/base' => '17140 w17 s3 w44 w13 r w33 w39',# 07 Dec 2016
# 'player-en_US-vfldNN9oa/base' => '17140 w17 s3 w44 w13 r w33 w39',# 10 Dec 2016
# 'player-en_US-vflK2s6tX/base' => '17141 w58 r s1 w66 r',        # 13 Dec 2016
# 'player-en_US-vflFKNtIl/base' => '17147 s2 w21 r s1 r s2 r',    # 14 Dec 2016
# 'player-en_US-vfljAVcXG/base' => '17149 s2 w51 r w62 w44 w65',  # 15 Dec 2016
# 'player-en_US-vflxP8f0T/base' => '17151 w47 s1 r w21 r w16 r',  # 19 Dec 2016
# 'player-en_US-vfla6wgHS/base' => '17151 w47 s1 r w21 r w16 r',  # 20 Dec 2016
# 'player-en_US-vflz_1lv2/base' => '17170 s2 r s2 w25 r s3 r',    # 05 Jan 2017
# 'player-en_US-vflsagga9/base' => '17175 s3 r w23 r w33 w51 s1 r w26',# 09 Jan 2017
# 'player-en_US-vflC029_L/base' => '17176 s2 r w17 r s2',         # 12 Jan 2017
# 'player-en_US-vfl4x5gM8/base' => '17177 r s2 r w5 s1 w7 r',     # 13 Jan 2017
# 'player-en_US-vflR62D9G/base' => '17177 r s2 r w5 s1 w7 r',     # 15 Jan 2017
# 'player-en_US-vflbh8HdB/base' => '17180 s2 w43 s2 r w35 r',     # 17 Jan 2017
# 'player-en_US-vflkZ4r_7/base' => '17180 s2 w43 s2 r w35 r',     # 19 Jan 2017
# 'player-en_US-vflamKXEP/base' => '17184 w42 w20 r w4 r s2',     # 20 Jan 2017
# 'player-en_US-vflHoC0VQ/base' => '17184 w42 w20 r w4 r s2',     # 20 Jan 2017
# 'player-en_US-vfl8Smq8T/base' => '17186 w37 w52 s3 w69 r',      # 23 Jan 2017
# 'player-en_US-vflNaXsht/base' => '17190 s1 r s2 r',             # 25 Jan 2017
# 'player-en_US-vflQBHHdn/base' => '17190 s1 r s2 r',             # 26 Jan 2017
# 'player-en_US-vflp0EuAP/base' => '17192 s2 w64 r s3',           # 31 Jan 2017
# 'player-en_US-vflkk7pUE/base' => '17192 s2 w64 r s3',           # 02 Feb 2017
# 'player-en_US-vflkRUE82/base' => '17199 w58 w66 s2 w70 r w56',  # 09 Feb 2017
# 'player-en_US-vfl8LqiZp/base' => '17199 w58 w66 s2 w70 r w56',  # 09 Feb 2017
# 'player-en_US-vflg9Wu9U/base' => '17206 s2 w48 r s2 w40 r w5 r',# 15 Feb 2017
# 'player-en_US-vflqOi6vK/base' => '17217 r s3 w53 s1 r w25 r',   # 22 Feb 2017
# 'player-en_US-vflVlxFvV/base' => '17217 r s3 w53 s1 r w25 r',   # 24 Feb 2017
# 'player-en_US-vflDQGgxm/base' => '17221 r w12 w69 r w50 r w61 r w10',# 01 Mar 2017
# 'player-en_US-vflOnuOF-/base' => '17229 w31 w23 r w26 r',       # 07 Mar 2017
# 'player-en_US-vfl67GkkS/base' => '17240 s1 w30 w63 w26 s3 w8 s2',# 15 Mar 2017
# 'player-en_US-vflk2jRfn/base' => '17240 s1 w30 w63 w26 s3 w8 s2',# 16 Mar 2017
# 'player-en_US-vfl7pRlZI/base' => '17240 s1 w30 w63 w26 s3 w8 s2',# 20 Mar 2017
# 'player-en_US-vfl8dRko7/base' => '17242 w11 s1 r s3',           # 21 Mar 2017
# 'player-en_US-vflTlQxIb/base' => '17245 w18 w46 s1 w56 r s3 r w53 s1',# 21 Mar 2017
# 'player-en_US-vflfbDY14/base' => '17246 s2 w55 s1',             # 22 Mar 2017
# 'player-en_US-vfl6bNiHm/base' => '17249 s2 r w38 r s3 r',       # 25 Mar 2017
# 'player-en_US-vflEzRdnB/base' => '17246 s2 w55 s1',             # 25 Mar 2017
# 'player-en_US-vflTzv1GM/base' => '17249 s2 r w38 r s3 r',       # 27 Mar 2017
# 'player-en_US-vfl5WC80G/base' => '17251 w37 r s3 w60 r w41',    # 28 Mar 2017
# 'player-en_US-vflwkOLTK/base' => '17252 w7 r w27 w34 r w56 w53 s1 r',# 29 Mar 2017
# 'player-en_US-vflgcceTZ/base' => '17252 w7 r w27 w34 r w56 w53 s1 r',# 30 Mar 2017
# 'player-en_US-vflPbFwAK/base' => '17254 s1 r w49 w29 s3 w59 w6 s2',# 30 Mar 2017
# 'player-en_US-vflRjgXJi/base' => '17256 w70 s1 r w63 r w46 w49 s1',# 01 Apr 2017
# 'player-en_US-vfld2g5gM/base' => '17258 w6 r s1 r',             # 03 Apr 2017
# 'player-en_US-vfl0d6UIe/base' => '17258 w6 r s1 r',             # 04 Apr 2017
# 'player-en_US-vfl-q4dPj/base' => '17258 w6 r s1 r',             # 06 Apr 2017
# 'player-en_US-vfl6_PD5A/base' => '17261 w7 s1 r s1 w2 s2 r',    # 06 Apr 2017
# 'player-en_US-vfliZaFqy/base' => '17263 w54 s3 w1 w36 s3',      # 07 Apr 2017
# 'player-en_US-vflqFHgLE/base' => '17261 w7 s1 r s1 w2 s2 r',    # 11 Apr 2017
# 'player-en_US-vflaxXRn1/base' => '17263 w54 s3 w1 w36 s3',      # 12 Apr 2017
# 'player-en_US-vfl5-0t5t/base' => '17269 s1 w44 r s1',           # 14 Apr 2017
# 'player-en_US-vflchU0AK/base' => '17270 w58 s1 r s2 w8 w21',    # 20 Apr 2017
# 'player-en_US-vflNZnmd3/base' => '17277 w66 r w54',             # 24 Apr 2017
# 'player-en_US-vflR14qD2/base' => '17277 w66 r w54',             # 25 Apr 2017
# 'player-vflppxuSE/en_US/base' => '17277 w66 r w54',             # 27 Apr 2017
# 'player-vflp8UEng/en_US/base' => '17291 r s3 r w45',            # 05 May 2017
# 'player-vfl3DiVMI/en_US/base' => '17293 w59 s3 w24 r w55 r s2 w38 w19',# 08 May 2017
# 'player-vfljmjb-X/en_US/base' => '17291 r s3 r w45',            # 11 May 2017
# 'player-vflxXnk_G/en_US/base' => '17295 r w27 r',               # 11 May 2017
# 'player-vfltmLGsd/en_US/base' => '17297 s2 w55 r s3 r',         # 16 May 2017
# 'player-vfl8jhACg/en_US/base' => '17303 w67 s3 r s2',           # 17 May 2017
# 'player-vfl4Xq3l4/en_US/base' => '17302 s3 r w43',              # 19 May 2017
# 'player-vfld8zR1S/en_US/base' => '17305 w16 s1 r s3 w33 s2 r s2',# 22 May 2017
# 'player-vfluaMKo6/en_US/base' => '17305 w16 s1 r s3 w33 s2 r s2',# 23 May 2017
# 'player-vflyC4_W-/en_US/base' => '17316 s1 r w24 s3 r w54 s1',  # 30 May 2017
# 'player-vflCqycGh/en_US/base' => '17316 s1 r w24 s3 r w54 s1',  # 01 Jun 2017
# 'player-vflZ_L_3c/en_US/base' => '17316 s1 r w24 s3 r w54 s1',  # 02 Jun 2017
# 'player-vflQZSd3x/en_US/base' => '17325 s3 r s1',               # 12 Jun 2017
# 'player-vflLxaaub/en_US/base' => '17329 s2 r w19 w60 s1 r w15 r s2',# 14 Jun 2017
# 'player-vfle90bgw/en_US/base' => '17329 s2 r w19 w60 s1 r w15 r s2',# 16 Jun 2017
# 'player-vfl2DpwLG/en_US/base' => '17333 w57 r w66',             # 19 Jun 2017
# 'player-vfl1Renoe/en_US/base' => '17336 r w38 r w67 w24 r s2',  # 20 Jun 2017
# 'player-vflmgXZN3/en_US/base' => '17338 s2 w33 w16 w44 s1 w12 r w19',# 23 Jun 2017
# 'player-vflPHG8dr/en_US/base' => '17342 r w12 r s2 w21 s3 w25 s1 r',# 25 Jun 2017
# 'player-vflAmElk-/en_US/base' => '17343 w4 r s1 w11 s1 w67 r',  # 27 Jun 2017
# 'player-vflV4eRc2/en_US/base' => '17344 w46 r w13 r w5 s3 w44 w51',# 28 Jun 2017
# 'player-vflotiWiu/en_US/base' => '17343 w4 r s1 w11 s1 w67 r',  # 29 Jun 2017
# 'player-vfl3RjfTG/en_US/base' => '17343 w4 r s1 w11 s1 w67 r',  # 05 Jul 2017
# 'player-vfl2U8fxZ/en_US/base' => '17353 r w70 w7 r s2 r s3',    # 06 Jul 2017
# 'player-vflDXt52J/en_US/base' => '17354 w39 s3 w70 r s3',       # 10 Jul 2017
# 'player-vflZQAwO8/en_US/base' => '17354 w39 s3 w70 r s3',       # 11 Jul 2017
# 'player-vflL_WLGI/en_US/base' => '17358 r w42 w32 r',           # 13 Jul 2017
# 'player-vflMaap-E/en_US/base' => '17364 r w13 r w28 r s3 r s3', # 19 Jul 2017
# 'player-vflGD0HaZ/en_US/base' => '17364 r w13 r w28 r s3 r s3', # 20 Jul 2017
# 'player-vflC3ZxIh/en_US/base' => '17368 w11 w55 w26',           # 24 Jul 2017
# 'player-vflp0IacK/en_US/base' => '17372 w68 s3 w24 s3 w55 r s2',# 27 Jul 2017
# 'player-vflrwQIQw/en_US/base' => '17374 r s2 r w19 s1',         # 27 Jul 2017
# 'player-vflRrT_TQ/en_US/base' => '17374 r s2 r w19 s1',         # 02 Aug 2017
# 'player-vflN55NZo/en_US/base' => '17379 s2 r s2 w37 s3 w4 w13 w17 s3',# 02 Aug 2017
# 'player-vfl8KhWdC/en_US/base' => '17380 w7 r w33 s2 w51 s2 w46 r s1',# 03 Aug 2017
# 'player-vflIVpVc9/en_US/base' => '17385 r s2 w1 s3 w11 w9 s2',  # 07 Aug 2017
# 'player-vflmw6aFG/en_US/base' => '17382 s3 r w36 s1 w48',       # 09 Aug 2017
# 'player-vflSyILh9/en_US/base' => '17387 s2 r w4 s1 w6',         # 14 Aug 2017
# 'player-vflBXnagy/en_US/base' => '17387 s2 r w4 s1 w6',         # 15 Aug 2017
# 'player-vflW7ch5Z/en_US/base' => '17393 r s1 r s2 r s2',        # 16 Aug 2017
# 'player-vflAAoWvh/en_US/base' => '17393 r s1 r s2 r s2',        # 17 Aug 2017
# 'player-vflTof4g1/en_US/base' => '17399 w25 w9 r',              # 23 Aug 2017
# 'player-vflK5H48T/en_US/base' => '17399 w25 w9 r',              # 23 Aug 2017
# 'player-vflyJ3OmM/en_US/base' => '17402 w65 s3 r s1 r s1 w58',  # 25 Aug 2017
# 'player-vfl2iVoNh/en_US/base' => '17403 s3 w51 w36 s3',         # 25 Aug 2017
# 'player-vflyFnz8E/en_US/base' => '17403 s3 w51 w36 s3',         # 28 Aug 2017
# 'player-vflWQ9tuM/en_US/base' => '17403 s3 w51 w36 s3',         # 30 Aug 2017
# 'player-vflaEZiBp/en_US/base' => '17403 s3 w51 w36 s3',         # 05 Sep 2017
# 'player-vflbWGdxe/en_US/base' => '17416 w38 r s1 w52 r w46 w49 r',# 07 Sep 2017
# 'player-vflm9jiGH/en_US/base' => '17416 w38 r s1 w52 r w46 w49 r',# 11 Sep 2017
# 'player-vflUDI8Xm/en_US/base' => '17416 w38 r s1 w52 r w46 w49 r',# 12 Sep 2017
# 'player-vfl8DkB0M/en_US/base' => '17422 s3 r w24 w61 r s3 r',   # 13 Sep 2017
# 'player-vflUnLBiU/en_US/base' => '17421 s3 r s1 w45 w25 s3',    # 14 Sep 2017
# 'player-vfliXTNRk/en_US/base' => '17423 r s3 r s3 w51 w8 s3 w21',# 18 Sep 2017
# 'player-vflxp5z1z/en_US/base' => '17423 r s3 r s3 w51 w8 s3 w21',# 19 Sep 2017
# 'player-vfl3pBiM5/en_US/base' => '17423 r s3 r s3 w51 w8 s3 w21',# 20 Sep 2017
# 'player-vflR94_oU/en_US/base' => '17423 r s3 r s3 w51 w8 s3 w21',# 22 Sep 2017
# 'player-vfldWu3iC/en_US/base' => '17434 s3 r s1 r w61 r s2 w28',# 26 Sep 2017
# 'player-vfls3Lf3-/en_US/base' => '17434 s3 r s1 r w61 r s2 w28',# 27 Sep 2017
# 'player-vflcAIVzv/en_US/base' => '17437 r w54 r',               # 28 Sep 2017
# 'player-vflGRNpAk/en_US/base' => '17436 s1 w50 r s3',           # 02 Oct 2017
# 'player-vfl1RKjMF/en_US/base' => '17442 s2 r s2',               # 04 Oct 2017
# 'player-vflOdyxa4/en_US/base' => '17444 s2 r w24 s2 w48 s3 r',  # 05 Oct 2017
# 'player-vflgfcuiz/en_US/base' => '17444 s2 r w24 s2 w48 s3 r',  # 09 Oct 2017
# 'player-vflgH8YLq/en_US/base' => '17448 r w49 s3 w34 s3 w6 s3', # 10 Oct 2017
# 'player-vflwcUIMe/en_US/base' => '17449 w31 r w13 w14 r s1 r w45 r',# 11 Oct 2017
# 'player-vflD3dhYB/en_US/base' => '17452 w41 r w37 w19',         # 17 Oct 2017
# 'player-vflHvONov/en_US/base' => '17455 s2 r s2 w20 r s3',      # 17 Oct 2017
# 'player-vflcNAJUd/en_US/base' => '17456 w16 s3 w6 r w40 s3 r w49',# 18 Oct 2017
# 'player-vflN-B5oM/en_US/base' => '17463 r w69 w9 s1',           # 24 Oct 2017
# 'player-vflC8Yy7I/en_US/base' => '17462 w70 s3 w59 r w46',      # 25 Oct 2017
# 'player-vflhIZIgy/en_US/base' => '17462 w70 s3 w59 r w46',      # 26 Oct 2017
# 'player-vflSjPnAo/en_US/base' => '17465 r w28 w62 r s1 r s1',   # 30 Oct 2017
# 'player-vfl1ElKmp/en_US/base' => '17469 s2 r w62 s2 w5',        # 31 Oct 2017
# 'player-vflhqxyp7/en_US/base' => '17469 s2 r w62 s2 w5',        # 01 Nov 2017
# 'player-vflg6eF8s/en_US/base' => '17471 w13 w48 r s3 w6',       # 02 Nov 2017
# 'player-vflv6AMZr/en_US/base' => '17473 w1 r s2 w16',           # 06 Nov 2017
# 'player-vflvYne1z/en_US/base' => '17473 w1 r s2 w16',           # 07 Nov 2017
# 'player-vfl8XKJyP/en_US/base' => '17478 s1 r w69 s2 w45 s3 r w64 s2',# 08 Nov 2017
# 'player-vfl97imvj/en_US/base' => '17478 s1 r w69 s2 w45 s3 r w64 s2',# 09 Nov 2017
# 'player-vflXHVFyU/en_US/base' => '17483 r w55 s3 w5 r w36 r w66',# 13 Nov 2017
# 'player-vflg_prv_/en_US/base' => '17486 w58 s3 r s2 w2 s3',     # 16 Nov 2017
# 'player-vflPDkkkL/en_US/base' => '17486 w58 s3 r s2 w2 s3',     # 16 Nov 2017
# 'player-vflM013co/en_US/base' => '17486 w58 s3 r s2 w2 s3',     # 16 Nov 2017
# 'player-vflYXLM5n/en_US/base' => '17488 r s2 w13 s3 w62 r w14', # 20 Nov 2017
# 'player-vflsCMP_E/en_US/base' => '17490 w31 s1 r s3',           # 21 Nov 2017
# 'player-vflJtN5rw/en_US/base' => '17494 w45 w69 w2 r s1 r s1 r',# 24 Nov 2017
# 'player-vflnNEucX/en_US/base' => '17492 w61 r s2 r',            # 27 Nov 2017
# 'player-vfl8BSHQD/en_US/base' => '17492 w61 r s2 r',            # 29 Nov 2017
# 'player-vfl32FIDY/en_US/base' => '17501 w48 r w24 r',           # 04 Dec 2017
# 'player-vfl_6lezG/en_US/base' => '17501 w48 r w24 r',           # 05 Dec 2017
# 'player-vflvODUt0/en_US/base' => '17501 w48 r w24 r',           # 06 Dec 2017
# 'player-vfl4OEYh9/en_US/base' => '17501 w48 r w24 r',           # 07 Dec 2017
# 'player-vflebAXY2/en_US/base' => '17508 s2 w60 w51 s3 w52 r w22',# 11 Dec 2017
# 'player-vflu-7yX5/en_US/base' => '17511 r s2 r s2 w69',         # 12 Dec 2017
# 'player-vflOQ79Pl/en_US/base' => '17512 w28 w47 r s1 r w6',     # 13 Dec 2017
# 'player-vflyoGrhd/en_US/base' => '17512 w28 w47 r s1 r w6',     # 14 Dec 2017
# 'player-vflalc4VN/en_US/base' => '17515 w52 w9 s3 r w19 r w44 r',# 18 Dec 2017
# 'player-vflQ3Cu6g/en_US/base' => '17533 w56 s3 w35 r s2 w57 s2',# 03 Jan 2018
# 'player-vflIfz8pB/en_US/base' => '17533 w56 s3 w35 r s2 w57 s2',# 04 Jan 2018
# 'player-vfluepRD8/en_US/base' => '17536 w30 w30 w10 s3',        # 08 Jan 2018
# 'player-vflmAXHDE/en_US/base' => '17539 w20 r w35 r s1 w60 r s2',# 09 Jan 2018
# 'player-vflAhnAPk/en_US/base' => '17539 w20 r w35 r s1 w60 r s2',# 10 Jan 2018
# 'player-vflLCGcm0/en_US/base' => '17541 s2 r s3 w27 s2',        # 11 Jan 2018
# 'player-vflsh1Hwx/en_US/base' => '17544 r s1 r w52 r s1 r s2',  # 16 Jan 2018
# 'player-vflNX6xa_/en_US/base' => '17547 r w14 s1 w66 s1 w9 w65 r',# 17 Jan 2018
# 'player-vfljg_2Dr/en_US/base' => '17549 w52 r s1 w56 s2 r',     # 22 Jan 2018
# 'player-vfleux_zG/en_US/base' => '17555 w15 w70 r w10 r w66 s3 w33 w24',# 24 Jan 2018
# 'player-vflX4ueE4/en_US/base' => '17555 w15 w70 r w10 r w66 s3 w33 w24',# 25 Jan 2018
# 'player-vflAZc3qd/en_US/base' => '17555 w15 w70 r w10 r w66 s3 w33 w24',# 29 Jan 2018
# 'player-vflVZNDz1/en_US/base' => '17555 w15 w70 r w10 r w66 s3 w33 w24',# 30 Jan 2018
# 'player-vflxuxnEY/en_US/base' => '17561 s3 r w49',              # 31 Jan 2018
# 'player-vflBjp0_H/en_US/base' => '17564 w1 s3 r',               # 06 Feb 2018
# 'player-vflG9lb96/en_US/base' => '17570 w26 r w8 w61',          # 08 Feb 2018
# 'player-vflNpPGQq/en_US/base' => '17570 w26 r w8 w61',          # 12 Feb 2018
# 'player-vflGoYKgz/en_US/base' => '17574 w6 w64 w25 w53 s2 r s3',# 14 Feb 2018
# 'player-vfl8swg2e/en_US/base' => '17574 w6 w64 w25 w53 s2 r s3',# 15 Feb 2018
# 'player-vflLdwQUM/en_US/base' => '17579 s2 w2 w51 w9 s2 r w15 s3',# 20 Feb 2018
# 'player-vflJmXkuH/en_US/base' => '17579 s2 w2 w51 w9 s2 r w15 s3',# 22 Feb 2018
# 'player-vflSVCOgl/en_US/base' => '17579 s2 w2 w51 w9 s2 r w15 s3',# 22 Feb 2018
# 'player-vfldJxavu/en_US/base' => '17579 s2 w2 w51 w9 s2 r w15 s3',# 26 Feb 2018
# 'player-vflC6bTWQ/en_US/base' => '17589 r s3 w35 s1 r w54',     # 27 Feb 2018
# 'player-vflGUPF-i/en_US/base' => '17595 r w23 s3 r w45 r w66',  # 06 Mar 2018
# 'player-vflCpS7fy/en_US/base' => '17595 r w23 s3 r w45 r w66',  # 07 Mar 2018
# 'player-vflpGF_3J/en_US/base' => '17595 r w23 s3 r w45 r w66',  # 08 Mar 2018
# 'player-vflqL4Jb8/en_US/base' => '17598 r s1 r w50',            # 10 Mar 2018
# 'player-vfllqtOs7/en_US/base' => '17598 r s1 r w50',            # 13 Mar 2018
# 'player-vfleo_x3O/en_US/base' => '17598 r s1 r w50',            # 14 Mar 2018
# 'player-vflHDhBq1/en_US/base' => '17598 r s1 r w50',            # 15 Mar 2018
# 'player-vflHP6k-6/en_US/base' => '17598 r s1 r w50',            # 17 Mar 2018
# 'player-vflrObaqJ/en_US/base' => '17606 w12 w18 r s3 r s3 w69 r s3',# 20 Mar 2018
# 'player-vfl33N9QG/en_US/base' => '17606 w12 w18 r s3 r s3 w69 r s3',# 21 Mar 2018
# 'player-vflMfSEyN/en_US/base' => '17606 w12 w18 r s3 r s3 w69 r s3',# 22 Mar 2018
# 'player-vflPBHrby/en_US/base' => '17606 w12 w18 r s3 r s3 w69 r s3',# 24 Mar 2018
# 'player_ias-vfl97oyaf/en_US/base' => '17614 r s2 w67 s3 r s3',  # 27 Mar 2018
# 'player-vfl7rrrdV/en_US/base' => '17616 r s3 r s3 w38 s1 w64 r s2',# 28 Mar 2018
# 'player-vflI0cIzU/en_US/base' => '17616 r s3 r s3 w38 s1 w64 r s2',# 29 Mar 2018
# 'player-vflENcx6t/en_US/base' => '17616 r s3 r s3 w38 s1 w64 r s2',# 03 Apr 2018
# 'player-vflE3xFS5/en_US/base' => '17616 r s3 r s3 w38 s1 w64 r s2',# 07 Apr 2018
# 'player-vflSawkIt/en_US/base' => '17616 r s3 r s3 w38 s1 w64 r s2',# 09 Apr 2018
# 'player-vflRhCLRy/en_US/base' => '17616 r s3 r s3 w38 s1 w64 r s2',# 11 Apr 2018
# 'player-vflX7BSrP/en_US/base' => '17632 s1 w70 w15 w3 r s2 r s2 r',# 12 Apr 2018
# 'player-vflUCrh9C/en_US/base' => '17633 s2 w12 w49 s1 r w68 r s3',# 16 Apr 2018
# 'player-vflZnIPED/en_US/base' => '17633 s2 w12 w49 s1 r w68 r s3',# 16 Apr 2018
# 'player-vflFcxzRO/en_US/base' => '17633 s2 w12 w49 s1 r w68 r s3',# 18 Apr 2018
# 'player-vflNLtm2_/en_US/base' => '17638 r w17 w14 s2 r',        # 23 Apr 2018
# 'player-vfl5ItJAe/en_US/base' => '17638 r w17 w14 s2 r',        # 24 Apr 2018
# 'player-vflPIRcoF/en_US/base' => '17638 r w17 w14 s2 r',        # 25 Apr 2018
# 'player-vfluI_BcD/en_US/base' => '17638 r w17 w14 s2 r',        # 26 Apr 2018
# 'player-vflp8wBqC/en_US/base' => '17647 s2 r s2 r s3 w60',      # 28 Apr 2018
# 'player-vflHFWD7-/en_US/base' => '17647 s2 r s2 r s3 w60',      # 01 May 2018
# 'player-vflfv8a8v/en_US/base' => '17647 s2 r s2 r s3 w60',      # 03 May 2018
# 'player-vflFw2plq/en_US/base' => '17655 r w51 r w24 s3 w70 r',  # 05 May 2018
# 'player-vfl5JMAdU/en_US/base' => '17655 r w51 r w24 s3 w70 r',  # 09 May 2018
# 'player-vflUPJQPD/en_US/base' => '17655 r w51 r w24 s3 w70 r',  # 09 May 2018
# 'player-vflxk5snu/en_US/base' => '17662 r w50 s2 r s3',         # 16 May 2018
# 'player-vflXIriOh/en_US/base' => '17662 r w50 s2 r s3',         # 17 May 2018
# 'player-vflBI1oYt/en_US/base' => '17662 r w50 s2 r s3',         # 22 May 2018
# 'player-vfllWbVhi/en_US/base' => '17662 r w50 s2 r s3',         # 23 May 2018
# 'player-vflqFr_Sb/en_US/base' => '17662 r w50 s2 r s3',         # 24 May 2018
# 'player_remote_ux-vflLhtyuT/en_US/base' => '17662 r w50 s2 r s3',# 24 May 2018
# 'player-vflKSi76_/en_US/base' => '17662 r w50 s2 r s3',         # 26 May 2018
# 'player-vflmV3Usi/en_US/base' => '17686 w21 s3 w41 r s1 w21 s1',# 05 Jun 2018
# 'player-vfl_RUk0U/en_US/base' => '17686 w21 s3 w41 r s1 w21 s1',# 06 Jun 2018
# 'player-vfl4qvcOS/en_US/base' => '17686 w21 s3 w41 r s1 w21 s1',# 06 Jun 2018
# 'player-vflr_Wq0V/en_US/base' => '17686 w21 s3 w41 r s1 w21 s1',# 09 Jun 2018
# 'player-vflT6zTz3/en_US/base' => '17693 w62 s1 r s3 w16 r',     # 12 Jun 2018
# 'player-vflkTAFWp/en_US/base' => '17696 s3 w44 s2 w34',         # 14 Jun 2018
# 'player-vfljt23et/en_US/base' => '17701 w60 s2 w31 r w33 s3',   # 19 Jun 2018
# 'player-vflT670_e/en_US/base' => '17702 r w7 w5 w6 r w63 w13',  # 20 Jun 2018
# 'player-vflpusdz-/en_US/base' => '17703 r w4 w19 s2 r w65 w1 r',# 21 Jun 2018
# 'player-vflWxIE9k/en_US/base' => '17707 w65 s1 r w56 w49 r s1 w60 s1',# 25 Jun 2018
# 'player-vflRPSMdq/en_US/base' => '17708 s3 r w6 r s2 r s2 r',   # 26 Jun 2018
# 'player-vfllebDdS/en_US/base' => '17709 s1 w14 w58 r s3 w38 r w14 w23',# 27 Jun 2018
# 'player-vflbyMNJ8/en_US/base' => '17710 w3 w28 s1 r w22',       # 28 Jun 2018
# 'player_ias-vflB7iQOt/en_US/base' => '17710 w3 w28 s1 r w22',   # 28 Jun 2018
# 'player-vflunOvo8/en_US/base' => '17710 w3 w28 s1 r w22',       # 28 Jun 2018
# 'player-vflG40-nw/en_US/base' => '17714 w45 r s2 r',            # 02 Jul 2018
# 'player-vfloLF805/en_US/base' => '17715 r w20 r w10 s1 w37 w32 s3',# 03 Jul 2018
# 'player-vflEPlHUY/en_US/base' => '17721 s3 r w58 r s3 w69',     # 09 Jul 2018
# 'player-vflAHKVO-/en_US/base' => '17722 w32 r s2 r w69 r s2 r', # 10 Jul 2018
# 'player-vflJjjlWD/en_US/base' => '17723 r s3 w23 w44 r s3',     # 12 Jul 2018
# 'player-vfl_lUmSJ/en_US/base' => '17724 w24 r w51 r w60',       # 12 Jul 2018
# 'player-vfl9zpg5e/en_US/base' => '17725 w1 r s1',               # 13 Jul 2018
# 'player_ias-vfl_mA0rx/en_US/base' => '17728 r s1 w11',          # 16 Jul 2018
# 'player-vflzCRPJh/en_US/base' => '17728 r s1 w11',              # 16 Jul 2018
# 'player_ias-vfl2WjsTu/en_US/base' => '17731 w51 r w17 r s2 w32 s2',# 19 Jul 2018
# 'player-vfl-Sv0Xf/en_US/base' => '17731 w51 r w17 r s2 w32 s2', # 19 Jul 2018
# 'player-vfllBzgpS/en_US/base' => '17733 w16 w44 s2 r w64 s1 w19',# 21 Jul 2018
# 'player_ias-vflrYD9L0/en_US/base' => '17735 w34 r s1 r w31 s1', # 23 Jul 2018
# 'player-vflo6HcQb/en_US/base' => '17737 s1 r s3 w67 r s2',      # 25 Jul 2018
# 'player-vflW8WdD_/en_US/base' => '17737 s1 r s3 w67 r s2',      # 26 Jul 2018
# 'player-vflb9tnhu/en_US/base' => '17740 r s1 r s2 w70 s1 r w45 r',# 28 Jul 2018
# 'player-vflmd36GJ/en_US/base' => '17742 s1 w18 r s1 r w60 s3',  # 31 Jul 2018
# 'player-vfliKu3Tk/en_US/base' => '17744 w9 r w11 w12 w56 r w1 s3 r',# 01 Aug 2018
# 'player_ias-vflSjBO9f/en_US/base' => '17745 r w48 r',           # 02 Aug 2018
# 'player_remote_ux-vflqcuXQQ/en_US/base' => '17745 r w48 r',     # 02 Aug 2018
# 'player-vflkrp3z6/en_US/base' => '17745 r w48 r',               # 02 Aug 2018
# 'player-vflDNC2vK/en_US/base' => '17749 w52 w13 w27 r s2 w12 r',# 06 Aug 2018
# 'player_ias-vflPDD_hw/en_US/base' => '17750 r s2 r s3 r',       # 07 Aug 2018
# 'player_ias-vflWkXN6I/en_US/base' => '17750 r s2 r s3 r',       # 08 Aug 2018
# 'player-vflm39o9Z/en_US/base' => '17751 s2 r s3 w54 w9 r s2 w4 s3',# 08 Aug 2018
# 'player-vflM-t6FF/en_US/base' => '17752 w13 s2 w69 r w7 r',     # 09 Aug 2018
# 'player-vflCT6NPT/en_US/base' => '17757 r s3 r s1 w42 s2 w45 r',# 14 Aug 2018
# 'player-vflbOM9Vw/en_US/base' => '17757 r s3 r s1 w42 s2 w45 r',# 14 Aug 2018
# 'player-vfl2n6fnF/en_US/base' => '17763 w4 s2 r s2 r s1',       # 20 Aug 2018
# 'player-vflvPJ1R-/en_US/base' => '17765 r w17 w23 r w19 s1 r w57 s1',# 22 Aug 2018
# 'player_ias-vflkstHEy/en_US/base' => '17765 r w17 w23 r w19 s1 r w57 s1',# 22 Aug 2018
# 'player-vflGZmBoI/en_US/base' => '17770 s2 w13 s1 r s1 w69 r',  # 27 Aug 2018
# 'player-vflEdLQ9n/en_US/base' => '17771 w23 s2 r w6',           # 28 Aug 2018
# 'player-vflZ8oBLt/en_US/base' => '17772 s1 w33 s2 r s2 w23 r w43 r',# 29 Aug 2018
# 'player_ias-vflAarKGf/en_US/base' => '17773 w7 w52 s2 w48 r',   # 30 Aug 2018
# 'player-vfliK45Zi/en_US/base' => '17773 w7 w52 s2 w48 r',       # 30 Aug 2018
# 'player-vflPJRQDm/en_US/base' => '17777 w3 r s1 r s1 r w61 w20 s2',# 03 Sep 2018
# 'player-vflkiBRCU/en_US/base' => '17780 w61 r w46',             # 06 Sep 2018
# 'player_ias-vflIVQ4xT/en_US/base' => '17781 r w30 r s1 r w61 s2 w70',# 07 Sep 2018
# 'player-vflvABTsY/en_US/base' => '17781 r w30 r s1 r w61 s2 w70',# 07 Sep 2018
# 'player-vflHei2l6/en_US/base' => '17782 w16 s1 w54',            # 08 Sep 2018
# 'player-vflXCnVjq/en_US/base' => '17785 w53 s3 r w4 s3',        # 11 Sep 2018
# 'player-vfl6tBysE/en_US/base' => '17786 r w13 s1 w16 r s2',     # 12 Sep 2018
# 'player-vflkUTZn2/en_US/base' => '17787 s2 w8 r w43 s2 w11 r',  # 13 Sep 2018
# 'player_ias-vflblC9dU/en_US/base' => '17787 s2 w8 r w43 s2 w11 r',# 13 Sep 2018
# 'player-vflxKLgto/en_US/base' => '17791 s1 r w61 r w48 w55 r',  # 17 Sep 2018
# 'player-vflvTxtee/en_US/base' => '17792 r w39 s2',              # 18 Sep 2018
# 'player-vfl8DfiXg/en_US/base' => '17793 w67 s3 r w4 r s3 r',    # 19 Sep 2018
# 'player-vflUpPEZ9/en_US/base' => '17795 s3 r w33 w58 w7 s3 w11 s1',# 21 Sep 2018
# 'player-vfl7GcuOz/en_US/base' => '17798 r w5 r s2 r s2',        # 24 Sep 2018
# 'player_ias-vflXs7juB/en_US/base' => '17798 r w5 r s2 r s2',    # 24 Sep 2018
# 'player-vfl07ioI6/en_US/base' => '17799 w50 r s2 r',            # 26 Sep 2018
# 'player-vflB24EJ3/en_US/base' => '17806 w23 r s2 r w68 w30 r s1',# 02 Oct 2018
# 'player-vfl-vYfC3/en_US/base' => '17807 w49 w25 w4 r w32 s1 w17 w23',# 03 Oct 2018
# 'player_ias-vfleYRcGJ/en_US/base' => '17807 w49 w25 w4 r w32 s1 w17 w23',# 03 Oct 2018
# 'player-vflFV3riw/en_US/base' => '17812 s1 r w45 w56 s3',       # 08 Oct 2018
# 'player-vfl8R-b3G/en_US/base' => '17813 s2 r s3 r s2 w32 w35',  # 09 Oct 2018
# 'player-vflGzpM1Y/en_US/base' => '17814 r s2 w35 s2 r w4 r',    # 10 Oct 2018
# 'player_ias-vflBYAvAP/en_US/base' => '17814 r s2 w35 s2 r w4 r',# 10 Oct 2018
# 'player-vflO1Ey5k/en_US/base' => '17814 r s2 w35 s2 r w4 r',    # 10 Oct 2018
# 'player-vflHCRjhV/en_US/base' => '17819 w33 w25 s1 w60 r s1 w70 r',# 15 Oct 2018
# 'player-vflATXXzL/en_US/base' => '17821 w67 s2 w33 w30 r',      # 17 Oct 2018
# 'player-vflICk6QU/en_US/base' => '17822 s1 w58 s3 r',           # 18 Oct 2018
# 'player_ias-vflOjC-XR/en_US/base' => '17822 s1 w58 s3 r',       # 18 Oct 2018
# 'player-vflrZpM9e/en_US/base' => '17824 s1 r w3 r s1',          # 20 Oct 2018
# 'player-vflsLe3jn/en_US/base' => '17827 r s3 w36 w9 s3 w31 r s2',# 23 Oct 2018
# 'player-vflQJVaZA/en_US/base' => '17828 w23 s3 w14 s1',         # 24 Oct 2018
# 'player_ias-vflTuSS6p/en_US/base' => '17829 r w29 r s2',        # 25 Oct 2018
# 'player-vflXM3IU_/en_US/base' => '17829 r w29 r s2',            # 25 Oct 2018
# 'player-vflVce_C4/en_US/base' => '17834 r s2 w35 r s2 w15 w48', # 30 Oct 2018
# 'player_ias-vfl4nRobu/en_US/base' => '17836 w2 s2 r w48 w47 s3 r',# 01 Nov 2018
# 'player-vflKOteNp/en_US/base' => '17836 w2 s2 r w48 w47 s3 r',  # 01 Nov 2018
# 'player-vfls4aurX/en_US/base' => '17841 w61 w13 w16 s1 r w43 s1 w52 r',# 06 Nov 2018
# 'player_ias_remote_ux-vfl-mZlA8/en_US/base' => '17841 w61 w13 w16 s1 r w43 s1 w52 r',# 06 Nov 2018
# 'player_ias-vfl6LN1Nj/en_US/base' => '17841 w61 w13 w16 s1 r w43 s1 w52 r',# 06 Nov 2018
# 'player_ias-vflxtHgXu/en_US/base' => '17845 r w23 r s2 w43 s1 w17',# 10 Nov 2018
# 'player-vflVKnssA/en_US/base' => '17845 r w23 r s2 w43 s1 w17', # 10 Nov 2018
# 'player_ias-vflplkb5-/en_US/base' => '17849 w31 r w1',          # 14 Nov 2018
# 'player_ias-vflof8Kxx/en_US/base' => '17850 w64 w66 s2 w49 s2 r',# 15 Nov 2018
# 'player-vflWnjS_n/en_US/base' => '17850 w64 w66 s2 w49 s2 r',   # 15 Nov 2018
# 'player_ias-vflfmGnOV/en_US/base' => '17855 w49 s3 r w44 w32 s3',# 20 Nov 2018
# 'player-vfl718orE/en_US/base' => '17855 w49 s3 r w44 w32 s3',   # 20 Nov 2018
# 'player_ias_remote_ux-vflQA1gIN/en_US/base' => '17855 w49 s3 r w44 w32 s3',# 20 Nov 2018
# 'player-vflyUEprh/en_US/base' => '17856 w36 s3 w20 r w70 s3 r w29',# 21 Nov 2018
# 'player-vflX9LQZI/en_US/base' => '17862 s1 r s2 w16 s1 r s2 w26',# 27 Nov 2018
# 'player-vfl-6ni-d/en_US/base' => '17863 w66 r s1 r',            # 28 Nov 2018
# 'player-vflBGiA6J/en_US/base' => '17864 w15 s3 w19 s3 r',       # 29 Nov 2018
# 'player-vflooFjaN/en_US/base' => '17865 w49 r w24 r',           # 30 Nov 2018
# 'player-vflRjqq_w/en_US/base' => '17869 w18 s2 w6 s2 r',        # 04 Dec 2018
# 'player-vflrVSewe/en_US/base' => '17871 w33 w18 s1 w34 r s2 r s2',# 06 Dec 2018
# 'player-vflf5K4kk/en_US/base' => '17871 w33 w18 s1 w34 r s2 r s2',# 06 Dec 2018
# 'player_ias-vflA8SWf9/en_US/base' => '17872 s1 w51 r s1 w67 s1 w16 r s1',# 07 Dec 2018
# 'player_ias-vflsBa1u2/en_US/base' => '17876 r w48 r w65',       # 11 Dec 2018
# 'player_ias-vflXas3a_/en_US/base' => '17877 s1 r w15 w8 r w12', # 12 Dec 2018
# 'player_ias-vfl4UMq4Z/en_US/base' => '17880 w22 w43 s1 w10 w8 r s3 r s3',# 15 Dec 2018
# 'player_ias-vflNodBFa/en_US/base' => '17882 s3 w57 r s1',       # 17 Dec 2018
# 'player_ias-vflztg6e0/en_US/base' => '17884 w59 w12 s2 r s1 w10 r',# 19 Dec 2018
# 'player_ias-vflSzU_20/en_US/base' => '17885 w34 r w68 s1 w38 r',# 20 Dec 2018
# 'player-vflpOZkP0/en_US/base' => '17885 w34 r w68 s1 w38 r',    # 20 Dec 2018
# 'player_ias-vflWb9AD2/en_US/base' => '17886 s3 w70 r w54 r w26 w43 r s1',# 21 Dec 2018
# 'player_ias-vflNriX6t/en_US/base' => '17903 w50 r w62 s1 w16 s1',# 07 Jan 2019
# 'player_ias-vfls55OIb/en_US/base' => '17905 w24 w56 r w5',      # 09 Jan 2019
# 'player_ias-vfl_235rs/en_US/base' => '17906 w15 w53 s3 r',      # 10 Jan 2019
# 'player_ias-vflsx9jEl/en_US/base' => '17908 s2 w63 s1 r s2 r w69 w47 w8',# 12 Jan 2019
# 'player_ias-vflzJWmZN/en_US/base' => '17910 s1 r w44',          # 14 Jan 2019
# 'player_ias-vfl-jbnrr/en_US/base' => '17913 w69 r w55 s1 r s2 r s3',# 17 Jan 2019
# 'player_ias-vflH-Ze7P/en_US/base' => '17915 r s2 r w61 s2 w42', # 19 Jan 2019
# 'player_ias-vflSfmvrF/en_US/base' => '17919 r w18 r',           # 23 Jan 2019
# 'player_ias-vflLIeur2/en_US/base' => '17920 w62 r w6 w2 w39 w2',# 24 Jan 2019
# 'player_ias-vflok_OV_/en_US/base' => '17921 w59 s3 w41 s1',     # 25 Jan 2019
# 'player_ias-vflemibiK/en_US/base' => '17922 w4 w1 w27 r s1 r s1 w11',# 26 Jan 2019
# 'player_ias-vflehrYuM/en_US/base' => '17926 s1 w63 w25',        # 30 Jan 2019
# 'player_ias-vfl71PH-c/en_US/base' => '17931 s2 r w55 s1 r w41 w24 r',# 04 Feb 2019
# 'player_ias-vflcS3GOw/en_US/base' => '17932 s1 w55 w49',        # 05 Feb 2019
# 'player_ias-vflYv1bWD/en_US/base' => '17933 s3 r w23 s1 w9 r w35 w45 s1',# 06 Feb 2019
# 'player_ias-vflP40QgO/en_US/base' => '17936 r s1 w50 w1',       # 09 Feb 2019
# 'player_ias-vflRtzyEV/en_US/base' => '17940 r s2 r s1 r',       # 13 Feb 2019
# 'player_ias-vfl9fQPE9/en_US/base' => '17947 w53 w17 r w42 w19 w3',# 20 Feb 2019
# 'player_ias-vflq4d8Te/en_US/base' => '17949 r s3 w22 r w58 s3', # 22 Feb 2019
# 'player_ias-vflkaDufl/en_US/base' => '17952 r w36 r w3 s1 r s2',# 25 Feb 2019
# 'player_ias-vflfI-Uux/en_US/base' => '17953 w12 s3 w15 r s3',   # 26 Feb 2019
# 'player_ias-vflX2rhq7/en_US/base' => '17954 w54 w25 s1 r w62 w35 w17',# 27 Feb 2019
# 'player_ias-vflpVg286/en_US/base' => '17957 w27 s1 r s1 r w27 s3 w24',# 02 Mar 2019
# 'player_ias-vflwK9E86/en_US/base' => '17960 w36 s1 r w48 w23 w66 s2',# 05 Mar 2019
# 'player_ias-vfl0Xjrhe/en_US/base' => '17960 w36 s1 r w48 w23 w66 s2',# 05 Mar 2019
# 'player_ias-vflca9-f7/en_US/base' => '17962 s2 r s3 r s1',      # 07 Mar 2019
# 'player_ias-vflgQJQnf/en_US/base' => '17967 w18 w39 r w65',     # 12 Mar 2019
# 'player_ias-vflkyt12p/en_US/base' => '17968 s2 w12 r w62 s1',   # 13 Mar 2019
# 'player_ias-vflhRp6T6/en_US/base' => '17969 w23 r s3 r w16 w61 w48 w47',# 14 Mar 2019
# 'player_ias-vfljLzLcF/en_US/base' => '17971 w8 s3 r s3',        # 16 Mar 2019
# 'player_ias-vfl0mwZa0/en_US/base' => '17974 s3 w61 s2 r s1 w48 s2 r',# 19 Mar 2019
# 'player_ias-vflELyWbw/en_US/base' => '17974 s3 w61 s2 r s1 w48 s2 r',# 19 Mar 2019
# 'player_ias-vflGPko2h/en_US/base' => '17976 w23 s1 r s2 r s1 r w23 s2',# 21 Mar 2019
# 'player_ias-vflrQPnxT/en_US/base' => '17981 w41 w33 w28 w18 w31 w23',# 26 Mar 2019
# 'player_ias-vflUi8DdH/en_US/base' => '17984 w53 s2 r s3 r s2 w60 s2 w27',# 29 Mar 2019
# 'player_ias-vflx77j21/en_US/base' => '17984 w53 s2 r s3 r s2 w60 s2 w27',# 29 Mar 2019
# 'player_ias-vflh3Ltot/en_US/base' => '17989 s1 w44 w68 r w59 w35 s3 w7',# 03 Apr 2019
# 'player_ias-vflo38I3N/en_US/base' => '17989 s1 w44 w68 r w59 w35 s3 w7',# 03 Apr 2019
# 'player_ias-vflNoyOhW/en_US/base' => '17990 w19 w16 r s2',      # 04 Apr 2019
# 'player_ias-vflLXg1wb/en_US/base' => '17992 w55 s1 w4 r',       # 06 Apr 2019
# 'player_ias-vflQXSOCw/en_US/base' => '17995 r w11 s3 r w12 r s3 r s3',# 09 Apr 2019
# 'player_ias-vflptN-I_/en_US/base' => '17995 r w11 s3 r w12 r s3 r s3',# 09 Apr 2019
# 'player_ias_remote_ux-vflu5jbVI/en_US/base' => '17995 r w11 s3 r w12 r s3 r s3',# 09 Apr 2019
# 'player_ias-vflCpof0M/en_US/base' => '18002 w11 r s1 w65',      # 16 Apr 2019
# 'player_ias-vfloNowYZ/en_US/base' => '18003 w7 r s2 r s3 r s1 r s3',# 17 Apr 2019
# 'player_ias-vflYEQ3rp/en_US/base' => '18005 r s2 w26 r s2 w70 r',# 19 Apr 2019
# 'player_ias-vflox1iTd/en_US/base' => '18009 w57 w32 s3 r',      # 23 Apr 2019
# 'player_ias-vflzZ-uwH/en_US/base' => '18010 w12 w24 r s2 w34 w62 s2 w70 s2',# 24 Apr 2019
# 'player_ias-vflU6l_su/en_US/base' => '18011 s1 r w56 s2 r s2 r',# 25 Apr 2019
# 'player_ias-vfl9qGq_O/en_US/base' => '18012 s3 r w4 r s2 w6 r', # 26 Apr 2019
# 'player_ias-vflXZ59b4/en_US/base' => '18016 w29 s2 r s2 r',     # 30 Apr 2019
# 'player_ias-vflOwsp3q/en_US/base' => '18017 s2 r w68 r s3',     # 01 May 2019
# 'player_ias-vfl61X81T/en_US/base' => '18019 r w58 s2 r s3 r s1 w70 r',# 03 May 2019
# 'player_ias-vflisCO7O/en_US/base' => '18022 s2 w36 s2',         # 06 May 2019
# 'player_ias-vflmRtaf6/en_US/base' => '18023 s3 w30 r s1 r s1 r s3',# 07 May 2019
# 'player_ias-vflQTyJbT/en_US/base' => '18024 w15 r w33 w28 s3 w11 s3 r',# 08 May 2019
# 'player_ias-vflHkKkEW/en_US/base' => '18025 w70 w67 w2 w19 r w45 w56 s3 r',# 09 May 2019
# 'player_ias-vfl5CuSGB/en_US/base' => '18030 r w42 w15 r',       # 14 May 2019
# 'player_ias-vflOR94oD/en_US/base' => '18031 s1 w41 s2',         # 15 May 2019
# 'player_ias-vflFo4HCs/en_US/base' => '18033 r s3 w4 w65 r w45 w50 s2',# 17 May 2019
# 'player_ias-vflj9IN-5/en_US/base' => '18037 r s1 w41 r w37 s3 r w27 r',# 21 May 2019
# 'player_ias-vfld3bR7p/en_US/base' => '18038 r w45 w33 r s2 r w36 w20 r',# 22 May 2019
# 'player_ias-vflusCuE1/en_US/base' => '18039 w35 s3 r w37 w1 w65',# 23 May 2019
# 'player_ias-vflS2RkAM/en_US/base' => '18040 w56 w48 s3 w64 s1 r s2 w43',# 24 May 2019
# 'player_ias-vfl1T0cVh/en_US/base' => '18041 s2 w62 r s3 w21 r w52',# 25 May 2019
# 'player_ias-vflVstpzG/en_US/base' => '18045 s2 r s2 r s2 r w51 r',# 29 May 2019
# 'player_ias-vfl6QiMWf/en_US/base' => '18045 s2 r s2 r s2 r w51 r',# 29 May 2019
# 'player_ias-vfl5VAqDi/en_US/base' => '18046 r w41 r w62 s2 r',  # 30 May 2019
# 'player_ias_remote_ux-vfldk63YK/en_US/base' => '18048 w64 w62 w66 r w29 r s3 r s1',# 01 Jun 2019
# 'player_ias-vfl-SOYuS/en_US/base' => '18051 s3 r s3 w61 r',     # 04 Jun 2019
# 'player_ias-vflo4i8HU/en_US/base' => '18052 s1 r s2',           # 05 Jun 2019
# 'player_ias-vfl25EWhw/en_US/base' => '18053 w38 r w7 w18 r w21',# 06 Jun 2019
# 'player_ias-vfldhBbts/en_US/base' => '18055 w12 w59 s2 w24 r',  # 08 Jun 2019
# 'player_ias-vflzbi_R5/en_US/base' => '18060 w40 w67 r w7 s1',   # 13 Jun 2019
# 'player_ias-vfltBCqwT/en_US/base' => '18065 r s3 r w65 r s1 r w20',# 18 Jun 2019
# 'player_ias-vfloOZja_/en_US/base' => '18066 w20 r w17',         # 19 Jun 2019
# 'player_ias-vfl49f_g4/en_US/base' => '18066 w20 r w17',         # 19 Jun 2019
# 'player_ias-vflnDDQuY/en_US/base' => '18071 w51 r w20 r s1 r s3 r',# 24 Jun 2019
# 'player_ias-vflIucxJp/en_US/base' => '18072 s2 r w54 s1',       # 25 Jun 2019
# 'player_ias-vflv00tk0/en_US/base' => '18072 s2 r w54 s1',       # 25 Jun 2019
# 'player_ias-vflxACNZ2/en_US/base' => '18074 w8 r w61 r s3 r w47 s2 w11',# 27 Jun 2019
# 'player_ias-vfliSA6ma/en_US/base' => '18079 s2 w5 s2 r',        # 02 Jul 2019
# 'player_ias-vfl7A4uZG/en_US/base' => '18081 s1 w24 s3',         # 04 Jul 2019
# 'player_ias-vflojvMjn/en_US/base' => '18086 r s3 r s2 r w42 r w14 w4',# 09 Jul 2019
# 'player_ias-vfladvVLE/en_US/base' => '18087 r w60 r s3 r w46',  # 10 Jul 2019
# 'player_ias-vflK6rDhN/en_US/base' => '18088 w70 s2 w47 s2 w31 s1',# 11 Jul 2019
# 'player_ias-vfl_2S9FT/en_US/base' => '18092 s2 w58 s3',         # 15 Jul 2019
# 'player_ias-vflH7QZGl/en_US/base' => '18092 s2 w58 s3',         # 15 Jul 2019
# 'player_ias-vflFxFa3y/en_US/base' => '18095 r s3 r w12 r',      # 18 Jul 2019
# 'player_ias-vfl_rJBTq/en_US/base' => '18101 w67 r s1 w61 r',    # 24 Jul 2019
# 'player_ias-vfl7A19HM/en_US/base' => '18102 r s1 r s1 r s1',    # 25 Jul 2019
# 'player_ias-vflan9mDf/en_US/base' => '18104 s3 w34 s1 w24 r w45',# 27 Jul 2019
# 'player_ias-vflPI0brM/en_US/base' => '18106 s2 w23 w22 r s3 w1 s1 r s2',# 29 Jul 2019
# 'player_ias-vfl3cxFuT/en_US/base' => '18114 s2 r s2 r s1 r',    # 06 Aug 2019
# 'player_ias-vfliz8bvh/en_US/base' => '18114 s2 r s2 r s1 r',    # 06 Aug 2019
# 'player_ias-vflazKpcG/en_US/base' => '18117 w3 r w59 s3 r w14 w14 s2',# 09 Aug 2019
# 'player_ias-vfl0ft1-Z/en_US/base' => '18117 w3 r w59 s3 r w14 w14 s2',# 09 Aug 2019
# 'player_ias-vflOQSPfo/en_US/base' => '18120 r w24 r w41 r w2',  # 12 Aug 2019
# 'player_ias-vfluLgj-p/en_US/base' => '18120 r w24 r w41 r w2',  # 12 Aug 2019
# 'player_ias-vfl4ZkW5S/en_US/base' => '18121 s2 r w45 r w23',    # 13 Aug 2019
# 'player_ias-vflLAbfAI/en_US/base' => '18122 w9 s3 r s3 r w27 r s1 w64',# 14 Aug 2019
# 'player_ias-vfl4WD7HR/en_US/base' => '18123 r w23 w30 r w40 r w65 w38',# 15 Aug 2019
# 'player_ias-vflubst9M/en_US/base' => '18123 r w23 w30 r w40 r w65 w38',# 15 Aug 2019
# 'player_ias-vflshR-OW/en_US/base' => '18127 r s1 w19',          # 19 Aug 2019
# 'player_ias-vflR4bDhL/en_US/base' => '18128 r w34 w50 s1 r w68',# 20 Aug 2019
# 'player_ias-vflRCamp0/en_US/base' => '18128 r w34 w50 s1 r w68',# 20 Aug 2019
# 'player_ias-vfle9vlRm/en_US/base' => '18130 w20 s1 r s3 w35',   # 22 Aug 2019
# 'player_ias-vflQ3KR0i/en_US/base' => '18130 w20 s1 r s3 w35',   # 22 Aug 2019
# 'player_ias-vflRUnhQH/en_US/base' => '18134 r s2 r w37 s1 w9 s1 r',# 26 Aug 2019
# 'player_ias-vflxmW2zg/en_US/base' => '18135 r s3 w56 r s3 w11 s2 w57',# 27 Aug 2019
# 'player_ias-vflkpoWE6/en_US/base' => '18135 r s3 w56 r s3 w11 s2 w57',# 27 Aug 2019
# 'player_ias-vflB-cY7Z/en_US/base' => '18137 s2 r s2 r w37 s2 r s1',# 29 Aug 2019
# 'player_ias-vflt4leIo/en_US/base' => '18138 w35 w30 r w2 s3 r w8 s2',# 30 Aug 2019
# 'player_ias-vflL8qGmP/en_US/base' => '18142 r s3 r w36 w42',    # 03 Sep 2019
# 'player_ias-vfl-_sce4/en_US/base' => '18143 r w52 r s1 w20 r',  # 04 Sep 2019
# 'player_ias-vfl9X5OgR/en_US/base' => '18143 r w52 r s1 w20 r',  # 04 Sep 2019
# 'player_ias-vflpfvoVH/en_US/base' => '18149 r w52 r w11 s2 r s2',# 10 Sep 2019
# 'player_ias-vfl2pEEGH/en_US/base' => '18151 w25 s3 w11 s1 w25 w29 r w28 s2',# 12 Sep 2019
# 'player_ias-vflbxHFzR/en_US/base' => '18152 r s2 w48 r',        # 13 Sep 2019
# 'player_ias-vfl8E5RS_/en_US/base' => '18154 r s2 r w14 w70 w51',# 15 Sep 2019
# 'player_ias-vflBg-eSP/en_US/base' => '18156 w15 r s1 w60 s2 w47 s3 r',# 17 Sep 2019
# 'player_ias-vflFWJS6F/en_US/base' => '18159 w67 s1 r s3',       # 20 Sep 2019
# 'player_ias-vfleGIwAA/en_US/base' => '18159 w67 s1 r s3',       # 20 Sep 2019
# 'player_ias-vflf1C3PW/en_US/base' => '18163 r w30 s3 w48 w54 s2',# 24 Sep 2019
# 'player_ias-vflSXUoF7/en_US/base' => '18164 w59 s3 w31 s2 w3 s3 r s1 r',# 25 Sep 2019
# 'player_ias-vfl-Yp-48/en_US/base' => '18166 r w69 w9 r w58 s3 r w8 s2',# 27 Sep 2019
# 'player_ias-vflKkjtvu/en_US/base' => '18169 w51 r s2',          # 30 Sep 2019
# 'player_ias-vflhIMmpR/en_US/base' => '18170 w24 w7 r w54 s1 r w65',# 01 Oct 2019
# 'player_ias-vflHafnhm/en_US/base' => '18171 s2 w36 w34',        # 02 Oct 2019
# 'player_ias-vflgyMPMy/en_US/base' => '18172 w15 r s1 w33 w44 w39 w38 r s1',# 03 Oct 2019
# 'player_ias-vflaagmZn/en_US/base' => '18174 w67 r w21 r s1',    # 05 Oct 2019
# 'player_ias-vflLF-qe_/en_US/base' => '18174 w67 r w21 r s1',    # 05 Oct 2019
# 'player_ias-vflm8XufX/en_US/base' => '18177 r w22 s3 w42 r',    # 08 Oct 2019
# 'player_ias-vflp-7p2p/en_US/base' => '18177 r w22 s3 w42 r',    # 08 Oct 2019
# 'player_ias-vflMzJYzW/en_US/base' => '18179 w68 s1 w57 r s1 w23 s1',# 10 Oct 2019
# 'player_ias-vflNSW9LL/en_US/base' => '18180 s2 r s3 w65 s3 r s1',# 11 Oct 2019
# 'player_ias-vflZy72vV/en_US/base' => '18183 w33 w37 w16 r s3',  # 14 Oct 2019
# 'player_ias-vflCPQUIL/en_US/base' => '18184 r w17 s1 w36 w37 s2',# 15 Oct 2019
# 'player_ias-vflqs_iv4/en_US/base' => '18185 w8 w43 r s1 w40 s1',# 16 Oct 2019
# 'player_ias-vflzOmLM_/en_US/base' => '18185 w8 w43 r s1 w40 s1',# 16 Oct 2019
# 'player_ias-vflrnurMS/en_US/base' => '18188 w26 s3 w15 w26 s2 r',# 19 Oct 2019
# 'player_ias-vflYUXieR/en_US/base' => '18190 w4 r w31 s1 r s1 r',# 21 Oct 2019
# 'player_ias-vflfmpDLj/en_US/base' => '18192 r w5 r s2 r w34 r w16 r',# 23 Oct 2019
# 'player_ias-vflID-9v_/en_US/base' => '18192 r w5 r s2 r w34 r w16 r',# 23 Oct 2019
# 'player_ias-vflsEMaQv/en_US/base' => '18193 r w18 w7 w12 s3 r', # 24 Oct 2019
# 'player_ias-vflje5zha/en_US/base' => '18194 s2 w31 s3 w32 w2 s1 r',# 25 Oct 2019
# 'player_ias-vflLT_S1E/en_US/base' => '18198 r w65 r',           # 29 Oct 2019
# 'player_ias-vflGnuoiU/en_US/base' => '18199 w1 r s1 r',         # 30 Oct 2019
# 'player_ias-vflO1GesB/en_US/base' => '18200 w13 w56 s2 r s2',   # 31 Oct 2019
# 'player_ias-vflaGJCFN/en_US/base' => '18211 s3 w64 w35 r',      # 11 Nov 2019
# 'player_ias-vflu-qpOO/en_US/base' => '18211 s3 w64 w35 r',      # 11 Nov 2019
# 'player_ias-vflFlp-mq/en_US/base' => '18214 w70 r w67 w34',     # 14 Nov 2019
# 'player_ias-vflhctYB3/en_US/base' => '18216 w6 r s2',           # 16 Nov 2019
# 'player_ias-vfl3Ub7Lu/en_US/base' => '18218 r s2 r s3',         # 18 Nov 2019
# 'player_ias-vflss95Jx/en_US/base' => '18219 s3 r w58 s1 w18',   # 19 Nov 2019
# 'player_ias-vfl8EyRMW/en_US/base' => '18219 s3 r w58 s1 w18',   # 19 Nov 2019
# 'player_ias-vflHWPv1o/en_US/base' => '18220 w68 r s1',          # 20 Nov 2019
# 'player_ias-vflaU3CuL/en_US/base' => '18222 r s3 r w15 w33 w26 w29 w4 s2',# 22 Nov 2019
# 'player_ias-vfly7X4ko/en_US/base' => '18225 s1 w24 r w23 w32',  # 25 Nov 2019
# 'player_ias-vflGkJskG/en_US/base' => '18227 r w24 r w25 s3 r',  # 27 Nov 2019
# 'player_ias-vflVQDSr2/en_US/base' => '18229 s1 r s2 r s3 w16 w1',# 29 Nov 2019
# 'player_ias-vfl5RP2xB/en_US/base' => '18233 w28 s3 w15 w58 w54 r s1',# 03 Dec 2019
# 'player_ias-vflvcmhHb/en_US/base' => '18234 w38 s1 w37 s3 r w65 w36 r s1',# 04 Dec 2019
# 'player_ias-vfliASpvT/en_US/base' => '18235 w52 s1 w68 w44 w57 s2 r',# 05 Dec 2019
# 'player_ias-vflYr569U/en_US/base' => '18235 w52 s1 w68 w44 w57 s2 r',# 05 Dec 2019
# 'player_ias-vflhdSMEK/en_US/base' => '18236 r w44 s3',          # 06 Dec 2019
# 'player_ias-vflDT4YKf/en_US/base' => '18240 w4 s3 r s3 w47',    # 10 Dec 2019
# 'player_ias-vflZn7_Zv/en_US/base' => '18240 w4 s3 r s3 w47',    # 10 Dec 2019
# 'player_ias-vfl7Ksmll/en_US/base' => '18242 w70 s2 w19 s3',     # 12 Dec 2019
# 'player_ias-vfl22ubNH/en_US/base' => '18249 w26 s1 r s2 r s1 w45 r',# 19 Dec 2019
# 'player_ias-vflMn34bn/en_US/base' => '18268 s1 r s1 w5',        # 07 Jan 2020
# 'player_ias-vflY-95hF/en_US/base' => '18269 w58 s2 r s1 r',     # 08 Jan 2020
# 'player_ias-vflDLieI-/en_US/base' => '18269 w58 s2 r s1 r',     # 08 Jan 2020
# 'player_ias-vflJiqSE7/en_US/base' => '18272 w32 w13 s2 r',      # 11 Jan 2020
# 'player_ias-vflO3yVXL/en_US/base' => '18281 w42 w65 s1 r',      # 20 Jan 2020
# 'player_ias-vflwruZYD/en_US/base' => '18282 s2 r w36',          # 21 Jan 2020
# 'player_ias-vfl7lL1_p/en_US/base' => '18284 w8 r s2 r s1 r w59 s2',# 23 Jan 2020
# 'player_ias-vfl1GpCbm/en_US/base' => '18290 w46 r s2 r',        # 29 Jan 2020
  'player_ias-vflbwmoEe/en_US/base' => '18295 r w51 r s2 w39 r w6 w58',# 03 Feb 2020
  'player_ias-vflZgL1a2/en_US/base' => '18298 s3 r s2 r w67 w11', # 06 Feb 2020
  'player_ias-vflrgVy3r/en_US/base' => '18302 r w53 w5',          # 10 Feb 2020
  'player_ias-vfla5PwTn/en_US/base' => '18302 r w53 w5',          # 10 Feb 2020
  'player_ias-vfl5eNx6Z/en_US/base' => '18304 s2 r w9 w53 r w52 w68 r',# 12 Feb 2020
  'player_ias-vflT0MlXN/en_US/base' => '18305 w8 r w57 w44 s1 w53 r',# 13 Feb 2020
  'player_ias-vflp5fPn0/en_US/base' => '18305 w8 r w57 w44 s1 w53 r',# 13 Feb 2020
  'player_ias-vfl3Rvzpw/en_US/base' => '18311 w26 r w18 s1 r s2 r w37 s1',# 19 Feb 2020
  'player_ias-vfl5Kte8U/en_US/base' => '18317 w30 w63 w15 s3 r w50 s3 r w58',# 25 Feb 2020
  'player_ias-vflMJC6WU/en_US/base' => '18323 r s3 w58 r s3 r w16 r w20',# 02 Mar 2020
  'player_ias-vfl1Ng2HU/en_US/base' => '18324 w34 s1 w69 s3 r s2 w53',# 03 Mar 2020
  'player_ias-vfle4a9aa/en_US/base' => '18324 w34 s1 w69 s3 r s2 w53',# 03 Mar 2020
  'player_ias-vfl5C38RC/en_US/base' => '18325 w50 s3 w33 r s2 w6 r w16 r',# 04 Mar 2020
  'player_ias-vflQm4drh/en_US/base' => '18330 s1 w21 r w34 w18 w63',# 09 Mar 2020
  'player_ias-vflQJ_oH3/en_US/base' => '18332 w61 r s2',          # 11 Mar 2020
  'player_ias-vflJMXyvH/en_US/base' => '18337 w29 w41 s2 w23 s2 r s2',# 17 Mar 2020
  'player_ias-vflSBTliv/en_US/base' => '18338 w15 s1 w43 s3 r s3',# 17 Mar 2020
  'player_ias-vflEO2H8R/en_US/base' => '18340 s3 w28 r s3',       # 19 Mar 2020
  'player_ias-vfl2Bfj4C/en_US/base' => '18341 w70 s1 w62 r w69 r s1',# 20 Mar 2020
  'player_ias-vflJalPc2/en_US/base' => '18344 r w23 w65 w53',     # 23 Mar 2020
  'player_ias-vfl_gAQka/en_US/base' => '18351 w45 s1 w52 r w36 r w2',# 30 Mar 2020
  'player_ias-vfluKIiVl/en_US/base' => '18352 r w67 w37 s2 w59',  # 31 Mar 2020
  'player_ias-vflBAN1y0/en_US/base' => '18352 r w67 w37 s2 w59',  # 31 Mar 2020
  'player_ias-vfl5cScu9/en_US/base' => '18353 r s3 r',            # 01 Apr 2020
  'player_ias-vfl6MUxK7/en_US/base' => '18354 w35 r w42 w11 w48 s3 w70 s1',# 02 Apr 2020
  'player_ias-vfl_CsZz6/en_US/base' => '18356 w22 w17 s2 r s1 w8',# 04 Apr 2020
  'player_ias-vfl6VLxLZ/en_US/base' => '18359 s3 w39 s2 w1 s1 w35 w51 s2 r',# 07 Apr 2020
  '4fbb4d5b/player_ias.vflset/en_US/base' => '18359 s3 w39 s2 w1 s1 w35 w51 s2 r',# 07 Apr 2020
  '5478d871/player_ias.vflset/en_US/base' => '18366 w38 w7 s2',   # 14 Apr 2020
  'f676c671/player_ias.vflset/en_US/base' => '18368 s2 w4 w46 s2 w34 w59 r',# 16 Apr 2020
  'bfb2a3b4/player_ias.vflset/en_US/base' => '18372 s3 w21 r s3 r w36',# 20 Apr 2020
  '45e4d51d/player_ias.vflset/en_US/base' => '18375 w17 w16 r w25 r w50 w35',# 23 Apr 2020
  '0374edcb/player_ias.vflset/en_US/base' => '18379 w8 w43 w10 w34',# 27 Apr 2020
  '64dddad9/player_ias.vflset/en_US/base' => '18382 r w69 r w40', # 30 Apr 2020
  '52b1e972/player_ias.vflset/en_US/base' => '18386 w25 w47 r s1 w47',# 04 May 2020
  '0acb4375/player_ias.vflset/en_US/base' => '18389 r s1 w23 s3 w51',# 07 May 2020
  '376e3c34/player_ias.vflset/en_US/base' => '18394 r s3 w26',    # 12 May 2020
  '70f6ca87/player_ias.vflset/en_US/base' => '18395 w24 w13 w22 w23 s1 w44 r w15',# 13 May 2020
  'c31ba6fc/player_ias.vflset/en_US/base' => '18396 s3 w35 r w7', # 14 May 2020
  'e3cd195e/player_ias.vflset/en_US/base' => '18400 r w5 w20 r s2 w52 r w66 r',# 18 May 2020
  '85548937/player_ias.vflset/en_US/base' => '18403 s2 r s3 w14 w68 r w49 w30 w69',# 21 May 2020
  '4583e272/player_ias.vflset/en_US/base' => '18407 w27 s1 r s2 r w43',# 25 May 2020
  'de455b1a/player_ias.vflset/en_US/base' => '18410 w11 w70 w8 w40',# 28 May 2020
  'c31b936c/player_ias.vflset/en_US/base' => '18414 w23 w59 s3 w33 w49 s3 r',# 01 Jun 2020
  '39dd62a0/player_ias.vflset/en_US/base' => '18417 w11 w29 s3 w69 r s2 r',# 05 Jun 2020
  '16a691a1/player_ias.vflset/en_US/base' => '18421 r s3 w1 w67 s2 w8',# 08 Jun 2020
  '0c5285fd/player_ias.vflset/en_US/base' => '18428 s1 r w18 w59',# 15 Jun 2020
  '1d33781a/player_ias.vflset/en_US/base' => '18432 r s1 r w28',  # 19 Jun 2020
  '5cc7c83f/player_ias.vflset/en_US/base' => '18435 s1 w29 r s3 w41 s2 w27 r',# 22 Jun 2020
  '68f00b39/player_ias.vflset/en_US/base' => '18438 r w15 s1 r w11 s2',# 25 Jun 2020
  '02c092a5/player_ias.vflset/en_US/base' => '18442 s2 r s1 r w37 s3',# 29 Jun 2020
  '54668ca9/player_ias.vflset/en_US/base' => '18444 r w43 r s3 r',# 01 Jul 2020
  '3662280c/player_ias.vflset/en_US/base' => '18449 s2 r w70',    # 06 Jul 2020
  '5253ac4d/player_ias.vflset/en_US/base' => '18456 r s3 r w70',  # 13 Jul 2020
  '8786a07b/player_ias.vflset/en_US/base' => '18463 r s2 r w29 r s1 r s3',# 20 Jul 2020
  '0bb3b162/player_ias.vflset/en_US/base' => '18466 w39 r w20',   # 23 Jul 2020
  'c718385a/player_ias.vflset/en_US/base' => '18473 w23 r w63 r s1 r',# 30 Jul 2020
  'e49bfb00/player_ias.vflset/en_US/base' => '18477 w4 r w15 s3 w24 w4 r w24',# 03 Aug 2020
  'c0a91787/player_ias.vflset/en_US/base' => '18480 w14 w61 s2 w28 w27 s3 w1 w20',# 06 Aug 2020
  '0a90460f/player_ias.vflset/en_US/base' => '18484 s1 r s1 w47', # 10 Aug 2020
  '0c815aae/player_ias.vflset/en_US/base' => '18487 w29 r w61 s2 w32 s3 w34',# 13 Aug 2020
  'cba0baa7/player_ias.vflset/en_US/base' => '18491 w27 w46 w22 r w46 s2 r w21',# 17 Aug 2020
  '530216c1/player_ias.vflset/en_US/base' => '18494 r s3 r w43',  # 20 Aug 2020
  'eecb0f1e/player_ias.vflset/en_US/base' => '18498 w20 w11 s3 r w27 r s2 r s2',# 24 Aug 2020
  '54d6fa95/player_ias.vflset/en_US/base' => '18501 s1 w39 s3',   # 27 Aug 2020
  '86f77974/player_ias.vflset/en_US/base' => '18505 r w69 r w20 r w32 s3',# 31 Aug 2020
  'bcf2977e/player_ias.vflset/en_US/base' => '18508 s2 w28 w46 r s1',# 03 Sep 2020
  '8c24a503/player_ias.vflset/en_US/base' => '18508 s2 w28 w46 r s1',# 04 Sep 2020
  '134332d3/player_ias.vflset/en_US/base' => '18516 s3 r w1 w3 w51 r',# 11 Sep 2020
  'e0d83c30/player_ias.vflset/en_US/base' => '18519 w32 r s1 r s3 r w28 s1',# 14 Sep 2020
  '4b1ba5ea/player_ias.vflset/en_US/base' => '18523 s3 w21 r s1 w27 w54 r s3',# 18 Sep 2020
  '9ce2f25a/player_ias.vflset/en_US/base' => '18526 r s2 r w51 s1 r',# 21 Sep 2020
  '12237e3d/player_ias.vflset/en_US/base' => '18529 s1 r s2',     # 24 Sep 2020
  '4c375770/player_ias.vflset/en_US/base' => '18536 s3 w41 s3 w3 s3 r',# 01 Oct 2020
  '1a1b48e5/player_ias.vflset/en_US/base' => '18540 s1 w45 r s3 r s1 w50 s1 r',# 05 Oct 2020
  '3c37ed48/player_ias.vflset/en_US/base' => '18547 r w15 r',     # 12 Oct 2020
  '00510e67/player_ias.vflset/en_US/base' => '18550 w62 r s1 w45 r s2 r',# 15 Oct 2020
  '5799986b/player_ias.vflset/en_US/base' => '18554 w29 r w38 r', # 19 Oct 2020
  '4a1799bd/player_ias.vflset/en_US/base' => '18557 s2 w30 r',    # 22 Oct 2020
  '9b65e980/player_ias.vflset/en_US/base' => '18561 r s3 w51 s2', # 26 Oct 2020
  'ec262be6/player_ias.vflset/en_US/base' => '18564 w67 s1 w49 s3 w52 r s1 w43 r',# 29 Oct 2020
  'c926146c/player_ias.vflset/en_US/base' => '18568 s1 w50 r s3 w34 r',# 02 Nov 2020
  '16e41f55/player_ias.vflset/en_US/base' => '18571 w64 w1 w25 w70 r s2',# 05 Nov 2020
  'ac4b0b03/player_ias.vflset/en_US/base' => '18575 w69 r s2 w56 s1 r s3 r',# 09 Nov 2020
  'c299662f/player_ias.vflset/en_US/base' => '18578 r s2 w65 s2 r s3 r w2',# 12 Nov 2020
  'a3726513/player_ias.vflset/en_US/base' => '18582 r w10 r s1 w13 s2 w15',# 16 Nov 2020
  '8b85eac2/player_ias.vflset/en_US/base' => '18585 w62 r s1 w67',# 19 Nov 2020
  '77da52cd/player_ias.vflset/en_US/base' => '18590 s3 r w69 s2 w41',# 24 Nov 2020
  '408be03a/player_ias.vflset/en_US/base' => '18596 w26 w1 r s2 r',# 30 Nov 2020
  '6dde7fb4/player_ias.vflset/en_US/base' => '18604 r s3 w54 s3 r s1',# 08 Dec 2020
  '03226028/player_ias.vflset/en_US/base' => '18606 s2 w62 r',    # 10 Dec 2020
  '62f90c99/player_ias.vflset/en_US/base' => '18610 w49 s3 w10 s1',# 14 Dec 2020
  'c88a8657/player_ias.vflset/en_US/base' => '18612 r s1 r w18 s3 w36 r w32 s3',# 16 Dec 2020
  '2e6e57d8/player_ias.vflset/en_US/base' => '18613 w9 w4 r w54 r',# 17 Dec 2020
  '5dd3f3b2/player_ias.vflset/en_US/base' => '18617 r w13 s3 r w69 s2 w58 r s1',# 21 Dec 2020
  '9f996d3e/player_ias.vflset/en_US/base' => '18634 s2 r s2 w1 w8',# 07 Jan 2021
  'bfb74eaf/player_ias.vflset/en_US/base' => '18645 s2 r w29',    # 18 Jan 2021
  '27cea338/player_ias.vflset/en_US/base' => '18652 w35 s2 w8 r w51',# 25 Jan 2021
  'c6df6ed7/player_ias.vflset/en_US/base' => '18653 w35 s3 r w44 s1',# 26 Jan 2021
  '7bc032d0/player_ias.vflset/en_US/base' => '18655 r w56 w14 w9 r w30 r s3',# 28 Jan 2021
  'f6ef8aad/player_ias.vflset/en_US/base' => '18659 s1 w34 s2 r w64 s1 w55 r s3',# 01 Feb 2021
  '4bc55fd6/player_ias.vflset/en_US/base' => '18660 s2 r s1',     # 02 Feb 2021
  '0e3144b6/player_ias.vflset/en_US/base' => '18662 r s1 r w10 r s3 w68 s3 w58',# 04 Feb 2021
  '31234943/player_ias.vflset/en_US/base' => '18667 s2 r s1 r s3 r s2 r w66',# 09 Feb 2021
  '0ce056a2/player_ias.vflset/en_US/base' => '18668 w55 w55 s2 r',# 10 Feb 2021
  '490079fb/player_ias.vflset/en_US/base' => '18669 r s1 r s3 r w61 w60',# 11 Feb 2021
  '6eebf7aa/player_ias.vflset/en_US/base' => '18673 w2 s2 w24',   # 15 Feb 2021
  '1c732901/player_ias.vflset/en_US/base' => '18676 r s3 w37 s3', # 18 Feb 2021
  '5a096a9f/player_ias.vflset/en_US/base' => '18680 w17 r s3 w12 s1 r w47 r',# 22 Feb 2021
  '392133a3/player_ias.vflset/en_US/base' => '18681 r s2 r w48 s1 w15 r',# 23 Feb 2021
  '4fe52f49/player_ias.vflset/en_US/base' => '18683 w20 s2 w13 r s3',# 25 Feb 2021
  '0d54190b/player_ias.vflset/en_US/base' => '18688 w18 r s1 w17 r w60 r s3 w39',# 02 Mar 2021
  'a09205f7/player_ias.vflset/en_US/base' => '18690 w33 r s1 r s1 r s2',# 04 Mar 2021
  'd91669a4/player_ias.vflset/en_US/base' => '18694 s2 r s1 w54 w14 w12 s3',# 08 Mar 2021
  '34a43f74/player_ias.vflset/en_US/base' => '18695 r w27 r s1 r w4 r w41 w41',# 09 Mar 2021
  'd29f3109/player_ias.vflset/en_US/base' => '18697 r w2 w25 r w21 s3 w35 s2 w70',# 11 Mar 2021
  'b2e56c01/player_ias.vflset/en_US/base' => '18701 w18 w37 w29 w21 s2 r w29 s2 r',# 15 Mar 2021
  '223a7479/player_ias.vflset/en_US/base' => '18702 s3 w54 w21 w23 w57 w2 r w22',# 16 Mar 2021
  '228f3ac7/player_ias.vflset/en_US/base' => '18708 s3 w54 r w39 r',# 22 Mar 2021
  '38c5f870/player_ias.vflset/en_US/base' => '18709 w51 r s3 w11 r s2 r',# 23 Mar 2021
  '9f1ab255/player_ias.vflset/en_US/base' => '18716 r s2 r w68 w66 r',# 30 Mar 2021
  '4ad4b014/player_ias.vflset/en_US/base' => '18717 s3 w63 w20 s1 r w44 s1',# 31 Mar 2021
  '3a4ee0a9/player_ias.vflset/en_US/base' => '18718 w9 w21 s3 r s3 w46 w67 r w15',# 01 Apr 2021
  '1c20fac3/player_ias.vflset/en_US/base' => '18722 w25 r s1 r s3 w65 w32 s1 r',# 05 Apr 2021
  '1d7f16b4/player_ias.vflset/en_US/base' => '18723 r w27 s3 w23 r w56 w46 r s1',# 06 Apr 2021
  'd2ff46c3/player_ias.vflset/en_US/base' => '18725 w19 s2 w2 w24',# 08 Apr 2021
  '2cea24bf/player_ias.vflset/en_US/base' => '18729 s1 w69 w1 w18 r w2',# 12 Apr 2021
  '82e684c7/player_ias.vflset/en_US/base' => '18730 s2 w9 r s3 r w53 r',# 13 Apr 2021
  'e0d06a61/player_ias.vflset/en_US/base' => '18732 s3 r s3 r s2 w4 w41 w41 r',# 15 Apr 2021
  'ba95ea16/player_ias.vflset/en_US/base' => '18736 w68 r w24 r s3 w67 s2 w16',# 19 Apr 2021
  'ae5b2092/player_ias.vflset/en_US/base' => '18737 w54 r w13 w7 w27 w19 w13',# 20 Apr 2021
  'fa244a41/player_ias.vflset/en_US/base' => '18739 s2 r s3 r w54 w51 r',# 22 Apr 2021
  'cb5bd7e6/player_ias.vflset/en_US/base' => '18744 s2 w5 r s1 r w41 s3',# 27 Apr 2021
  '901932ee/player_ias.vflset/en_US/base' => '18746 s1 w26 w38 s3 r w53 w35 w24 s2',# 29 Apr 2021
  'bce81a70/player_ias.vflset/en_US/base' => '18747 w50 w48 w23 w31',# 30 Apr 2021
  '3e7e4b43/player_ias.vflset/en_US/base' => '18750 s2 w47 s1 r s2 w4 r w15 w40',# 03 May 2021
  'bffc6f9f/player_ias.vflset/en_US/base' => '18751 s3 w7 w50 r s2 r w38',# 04 May 2021
  '838cc154/player_ias.vflset/en_US/base' => '18753 w41 s3 r s2 r w62 s3 w69 s2',# 06 May 2021
  '8fd60c09/player_ias.vflset/en_US/base' => '18758 s2 w18 s2 w50 s1 w44 w54 r',# 11 May 2021
  '24fb4fc5/player_ias.vflset/en_US/base' => '18758 s2 w18 s2 w50 s1 w44 w54 r',# 11 May 2021
  'b2ff0586/player_ias.vflset/en_US/base' => '18760 s2 w45 w38 s2 r s2',# 13 May 2021
  '08244190/player_ias.vflset/en_US/base' => '18764 w46 r s3',    # 17 May 2021
  'fba90263/player_ias.vflset/en_US/base' => '18766 s2 r s3',     # 19 May 2021
  '3d0175c7/player_ias.vflset/en_US/base' => '18767 w68 s1 r',    # 20 May 2021
  'c39bcc11/player_ias.vflset/en_US/base' => '18768 r s1 w6 s3 w34 r s1 w37',# 21 May 2021
  '8523e85c/player_ias.vflset/en_US/base' => '18771 w16 r s3 r w49 w50 w67 w22',# 24 May 2021
  'e467278e/player_ias.vflset/en_US/base' => '18772 s3 r s1 r w59 s2 w15 r w21',# 25 May 2021
  '0b643cd1/player_ias.vflset/en_US/base' => '18774 w57 r w13 r s1 w40 s1 w19',# 27 May 2021
  '5d68a2c6/player_ias.vflset/en_US/base' => '18778 s3 w5 w46 s1 r s3 w20',# 31 May 2021
  '5d56cf74/player_ias.vflset/en_US/base' => '18781 w65 r w38 r s2',# 04 Jun 2021
  '00fe505f/player_ias.vflset/en_US/base' => '18785 w36 s3 r',    # 07 Jun 2021
  '68cc98b3/player_ias.vflset/en_US/base' => '18786 r s2 r s3 r s3 w34 s2',# 08 Jun 2021
  '1fe59655/player_ias.vflset/en_US/base' => '18786 r s2 r s3 r s3 w34 s2',# 08 Jun 2021
  'a0094ae9/player_ias.vflset/en_US/base' => '18788 r w47 r s1',  # 10 Jun 2021
  'a7cbbf24/player_ias.vflset/en_US/base' => '18788 r w47 r s1',  # 10 Jun 2021
  '2a6f5e06/player_ias.vflset/en_US/base' => '18792 w5 r s1 w62 s1 r w48 w36 s1',# 14 Jun 2021
  '997fe684/player_ias.vflset/en_US/base' => '18793 w24 s2 w43 w36 s3 r s3 r w32',# 15 Jun 2021
  'da9443d1/player_ias.vflset/en_US/base' => '18795 w49 w26 r w62 r s2',# 17 Jun 2021
  '2fa3f946/player_ias.vflset/en_US/base' => '18799 w70 r w64 r w70 r w61',# 21 Jun 2021
  'b4c937ab/player_ias.vflset/en_US/base' => '18801 r w45 w32',   # 23 Jun 2021
  '11aba956/player_ias.vflset/en_US/base' => '18802 r w15 s3 w17',# 24 Jun 2021
  '1a0ca43b/player_ias.vflset/en_US/base' => '18806 w3 r s2',     # 28 Jun 2021
  '7acefd5d/player_ias.vflset/en_US/base' => '18808 w52 r s1',    # 30 Jun 2021
  '1eb201ea/player_ias.vflset/en_US/base' => '18815 r s2 r w6 s3 w28',# 07 Jul 2021
  '51ff6aac/player_ias.vflset/en_US/base' => '18816 s3 r s3 w24 s2 w53',# 08 Jul 2021
  'e5748921/player_ias.vflset/en_US/base' => '18820 r w18 r w44 w43 s3',# 12 Jul 2021
  'bec4196e/player_ias.vflset/en_US/base' => '18822 w31 s3 w11 w53 s3 w7',# 14 Jul 2021
  '7ba2b998/player_ias.vflset/en_US/base' => '18823 s1 w28 w14 r w6 s2 r',# 15 Jul 2021
  '375e32fd/player_ias.vflset/en_US/base' => '18827 w66 s3 w55 w29 r w27 r',# 19 Jul 2021
  '3804dce2/player_ias.vflset/en_US/base' => '18829 w41 s3 w44 s1',# 21 Jul 2021
  '408a20d8/player_ias.vflset/en_US/base' => '18830 w58 s3 w64 s2 r w41 r w25 s3',# 22 Jul 2021
  '02486e7d/player_ias.vflset/en_US/base' => '18834 w60 r w24 w13',# 26 Jul 2021
  '4aeb5fe3/player_ias.vflset/en_US/base' => '18836 s3 w63 r w31',# 28 Jul 2021
  '3c3086a1/player_ias.vflset/en_US/base' => '18837 w23 r w49 w39 s2',# 29 Jul 2021
  '2840754e/player_ias.vflset/en_US/base' => '18841 w43 r w36 w50 s3 w5 r w47 r',# 02 Aug 2021
  '850eb2bc/player_ias.vflset/en_US/base' => '18843 s2 r s1',     # 04 Aug 2021
  'be9c9f3b/player_ias.vflset/en_US/base' => '18844 w24 w30 s2 w57 w41 w70 w34 s1',# 05 Aug 2021
  '4224c673/player_ias.vflset/en_US/base' => '18848 w48 r s3 r s3 r w58 r',# 09 Aug 2021
  'a081deec/player_ias.vflset/en_US/base' => '18850 s3 w4 w35 s3 w63 s2 r w51 s3',# 11 Aug 2021
  '50e823fc/player_ias.vflset/en_US/base' => '18851 r w43 w37 r s1 w60 r w39',# 12 Aug 2021
  '28f65009/player_ias.vflset/en_US/base' => '18857 s3 r s3',     # 18 Aug 2021
  'b555ee94/player_ias.vflset/en_US/base' => '18858 w51 s3 w28 w29 w3 w47 r w1',# 19 Aug 2021
  '31389f53/player_ias.vflset/en_US/base' => '18862 w39 r w41',   # 23 Aug 2021
  'ee7f98d9/player_ias.vflset/en_US/base' => '18864 s3 w4 s2 r s1 w37 s3',# 25 Aug 2021
  '528656c7/player_ias.vflset/en_US/base' => '18865 r s2 w64 r w68 s3 w56 w49 s3',# 26 Aug 2021
  'c29c59cf/player_ias.vflset/en_US/base' => '18869 w19 w39 s3',  # 30 Aug 2021
  'f5eab513/player_ias.vflset/en_US/base' => '18871 w49 s3 w2 r w27 s2',# 01 Sep 2021
  '9da24d97/player_ias.vflset/en_US/base' => '18872 w59 w17 r',   # 02 Sep 2021
  'a1c3b4e5/player_ias.vflset/en_US/base' => '18876 r w39 s3',    # 06 Sep 2021
  'c21a8219/player_ias.vflset/en_US/base' => '18878 w27 w66 r w27 w53 s3 w18 s3',# 08 Sep 2021
  '1cc7c82c/player_ias.vflset/en_US/base' => '18879 r s3 w12 s2 w58 r s3 w42 s3',# 09 Sep 2021
  '1256b7e2/player_ias.vflset/en_US/base' => '18883 w12 s3 w28',  # 13 Sep 2021
  'd7a19ed1/player_ias.vflset/en_US/base' => '18886 r s2 w15 w15 s3',# 16 Sep 2021
  '202721c6/player_ias.vflset/en_US/base' => '18890 s3 w35 r s3 r',# 20 Sep 2021
  '54d85b95/player_ias.vflset/en_US/base' => '18893 w70 s3 w17 s2 r w37 s1',# 23 Sep 2021
  'd82ca80e/player_ias.vflset/en_US/base' => '18894 r s3 r s1 w43 w42',# 25 Sep 2021
  '9fd4fd09/player_ias.vflset/en_US/base' => '18900 r w37 s3 r s1 r s1 w9',# 30 Sep 2021
  'd33d444d/player_ias.vflset/en_US/base' => '18904 r w9 w25 r',  # 04 Oct 2021
  '37e2b9da/player_ias.vflset/en_US/base' => '18906 s1 r s2',     # 06 Oct 2021
  '920e4583/player_ias.vflset/en_US/base' => '18907 w66 r w11 s2',# 07 Oct 2021
  '387dfd49/player_ias.vflset/en_US/base' => '18911 s1 w53 s3 w10 w5 w12 s3 r',# 11 Oct 2021
  '5ba7be96/player_ias.vflset/en_US/base' => '18913 s1 w24 s3 w35 s2',# 13 Oct 2021
  '03869671/player_ias.vflset/en_US/base' => '18914 s2 r s3 r s3 r s3 r w11',# 14 Oct 2021
  '9e457a67/player_ias.vflset/en_US/base' => '18918 w57 s2 r s3', # 18 Oct 2021
  '26b082a8/player_ias.vflset/en_US/base' => '18920 w3 s2 r s2 w47 s1',# 20 Oct 2021
  'bc6d77fc/player_ias.vflset/en_US/base' => '18925 r w19 r s3 w48 r s1',# 25 Oct 2021
  '9a0939d3/player_ias.vflset/en_US/base' => '18926 w51 w23 r w8',# 26 Oct 2021
  '9216d1f7/player_ias.vflset/en_US/base' => '18927 w35 s2 w46 r',# 27 Oct 2021
  'f8cb7a3b/player_ias.vflset/en_US/base' => '18932 r s2 r w1 r s1 w56 s1 r',# 01 Nov 2021
  '8eb5bf0c/player_ias.vflset/en_US/base' => '18934 s3 r s3',     # 03 Nov 2021
  'ea6a4ba6/player_ias.vflset/en_US/base' => '18939 w1 s3 w54 r', # 08 Nov 2021
  '8d287e4d/player_ias.vflset/en_US/base' => '18942 r s2 r',      # 11 Nov 2021
  '2dfe380c/player_ias.vflset/en_US/base' => '18946 w38 r s3 r w19 w29 w26 w33 s3',# 15 Nov 2021
  '68e11abe/player_ias.vflset/en_US/base' => '18948 w13 r s1 r w65 s3',# 17 Nov 2021
  'ad2aeb77/player_ias.vflset/en_US/base' => '18949 w22 w31 r w55 s1 w67 w31',# 18 Nov 2021
  'a4610635/player_ias.vflset/en_US/base' => '18950 w38 r w12 w63 r w25',# 19 Nov 2021
  '4c89207b/player_ias.vflset/en_US/base' => '18952 s1 w52 w34 w39 s2 r s1 r s3',# 21 Nov 2021
  '10df06bb/player_ias.vflset/en_US/base' => '18954 w44 w64 w48 w7 s3 r',# 23 Nov 2021
  '3ce4f9b8/player_ias.vflset/en_US/base' => '18960 r w37 r w45 w8 r',# 29 Nov 2021
  'eea703f3/player_ias.vflset/en_US/base' => '18962 r w22 r w33 s2',# 01 Dec 2021
  '54223c10/player_ias.vflset/en_US/base' => '18963 r w40 s3 w56 w59 r',# 02 Dec 2021
  '8040e515/player_ias.vflset/en_US/base' => '18965 r s1 r s2 w12 r w18 r',# 05 Dec 2021
  '0c96dfd3/player_ias.vflset/en_US/base' => '18967 w43 w29 r w6 w45 r w40',# 06 Dec 2021
  '46ac5f60/player_ias.vflset/en_US/base' => '18968 r s1 w30',    # 07 Dec 2021
  'a515f6d1/player_ias.vflset/en_US/base' => '18969 r w63 s3 r s1 r s2',# 08 Dec 2021
  'dc05ba20/player_ias.vflset/en_US/base' => '18970 r w48 r s1',  # 10 Dec 2021
  '204bfffb/player_ias.vflset/en_US/base' => '18975 r w70 s2',    # 14 Dec 2021
  'f3c4e04d/player_ias.vflset/en_US/base' => '18976 w32 r w70',   # 15 Dec 2021
  '13e70377/player_ias.vflset/en_US/base' => '18977 r s3 r w53 w36 r s2 w59',# 16 Dec 2021
  '8da38e9a/player_ias.vflset/en_US/base' => '18978 r s3 w19 s2 w7 w58 r s2 r',# 17 Dec 2021
  'edff9f99/player_ias.vflset/en_US/base' => '18997 w4 w11 r s1 w54 w4 r w18',# 05 Jan 2022
  'f93a7034/player_ias.vflset/en_US/base' => '19002 w29 w9 s3 r s1 w53',# 10 Jan 2022
  '18da33ed/player_ias.vflset/en_US/base' => '19005 s1 w67 s2 r s3',# 13 Jan 2022
  '2b718ca6/player_ias.vflset/en_US/base' => '19011 r s3 r w32 w61 w25 s3 r s1',# 19 Jan 2022
  '94ee882e/player_ias.vflset/en_US/base' => '19012 s3 r w31 s1 r s2 r',# 20 Jan 2022
  '6087f117/player_ias.vflset/en_US/base' => '19016 r w13 s2 r w70 s3 w29',# 24 Jan 2022
  '8ad9c87a/player_ias.vflset/en_US/base' => '19018 s3 r s3 r s3',# 26 Jan 2022
  '495d0f2b/player_ias.vflset/en_US/base' => '19019 s2 w49 r s2 w5 w14 r',# 27 Jan 2022
  'e06dea74/player_ias.vflset/en_US/base' => '19023 s1 w45 r',    # 31 Jan 2022
  'cdb8d439/player_ias.vflset/en_US/base' => '19025 s1 w23 s1',   # 02 Feb 2022
  '0cd11746/player_ias.vflset/en_US/base' => '19026 s1 r s1',     # 03 Feb 2022
  '326d75a6/player_ias.vflset/en_US/base' => '19030 r w14 s3 w23 r s3 r s2',# 07 Feb 2022
  '96dcbc8c/player_ias.vflset/en_US/base' => '19032 w55 r s1 w18',# 09 Feb 2022
  '41de1c08/player_ias.vflset/en_US/base' => '19037 w45 r w31',   # 14 Feb 2022
  '4512a530/player_ias.vflset/en_US/base' => '19039 r w3 s2 w57 s1 r',# 16 Feb 2022
  'c3125ad0/player_ias.vflset/en_US/base' => '19040 w40 r w27 w33 w17 s2 r',# 17 Feb 2022
  'd2cc1285/player_ias.vflset/en_US/base' => '19044 s2 r w54 s2 w62',# 21 Feb 2022
  'ad8ea84d/player_ias.vflset/en_US/base' => '19046 s2 w17 w31 s2 r',# 23 Feb 2022
  '450209b9/player_ias.vflset/en_US/base' => '19047 r s3 w22 s1 w43 s3 r s1 w28',# 24 Feb 2022
  '9c1a7c38/player_ias.vflset/en_US/base' => '19051 w52 w19 w37 r w6',# 28 Feb 2022
  '0abde7de/player_ias.vflset/en_US/base' => '19054 r s3 r s1 r', # 03 Mar 2022
  '2fd2ad45/player_ias.vflset/en_US/base' => '19058 r s2 r w30 s1',# 07 Mar 2022
  '6d3a4914/player_ias.vflset/en_US/base' => '19060 s2 w22 w53 w26 r w48 s1 r w3',# 09 Mar 2022
  '87b9576a/player_ias.vflset/en_US/base' => '19061 s1 w34 r',    # 10 Mar 2022
  'bd67d609/player_ias.vflset/en_US/base' => '19065 r s3 w54 s1 r',# 14 Mar 2022
  '006430cb/player_ias.vflset/en_US/base' => '19067 r s1 w4 s3 r s2',# 16 Mar 2022
  '577098c0/player_ias.vflset/en_US/base' => '19068 w65 w57 r s1 r',# 17 Mar 2022
  '293baa5d/player_ias.vflset/en_US/base' => '19072 s1 r s3 w66 w9',# 21 Mar 2022
  '68423b67/player_ias.vflset/en_US/base' => '19074 w7 r w24 s3', # 23 Mar 2022
  'c6736352/player_ias.vflset/en_US/base' => '19075 s2 r s2 r',   # 24 Mar 2022
  '3a393eba/player_ias.vflset/en_US/base' => '19079 r w31 s2 w27 s2 w70 r s2 r',# 28 Mar 2022
  '1d26561d/player_ias.vflset/en_US/base' => '19081 s2 r w40 s1', # 30 Mar 2022
  '449ea0a5/player_ias.vflset/en_US/base' => '19082 s1 w31 s1 r s2 w19 s1',# 31 Mar 2022
  '9e50a907/player_ias.vflset/en_US/base' => '19086 w34 s2 w28 r w58',# 04 Apr 2022
  '689586e2/player_ias.vflset/en_US/base' => '19088 r s3 w20 s1', # 06 Apr 2022
  '3b5d5649/player_ias.vflset/en_US/base' => '19089 r s3 w17 s3', # 07 Apr 2022
  '1e29bfc0/player_ias.vflset/en_US/base' => '19093 w43 s3 r w47 s2 w57',# 11 Apr 2022
  '0c665041/player_ias.vflset/en_US/base' => '19095 r w38 r w46 s1 r w64 s1 r',# 13 Apr 2022
  'fae06c11/player_ias.vflset/en_US/base' => '19096 w64 s1 r',    # 14 Apr 2022
  '19eb72e4/player_ias.vflset/en_US/base' => '19100 w17 w18 w3 r w69 r w23',# 18 Apr 2022
  'ae36df5c/player_ias.vflset/en_US/base' => '19102 r s1 r w65 r s3 r',# 20 Apr 2022
  '534c466c/player_ias.vflset/en_US/base' => '19103 s2 w34 s2 w35 r',# 21 Apr 2022
  '596ef930/player_ias.vflset/en_US/base' => '19107 s1 r w37 w27 w11',# 25 Apr 2022
  'fe8185e7/player_ias.vflset/en_US/base' => '19109 s2 r s2 w33 s1 r w19',# 27 Apr 2022
  '9cdfefcf/player_ias.vflset/en_US/base' => '19110 s2 r w44 s2 r w29 w32',# 28 Apr 2022
  'dfe7ea14/player_ias.vflset/en_US/base' => '19114 w50 w22 s2 r s3 w25 r s1 w52',# 02 May 2022
  '7e5c03a3/player_ias.vflset/en_US/base' => '19115 s2 w25 w49 r s2',# 03 May 2022
  'a4d8b401/player_ias.vflset/en_US/base' => '19117 s2 r s2 r s3 r s3 r',# 05 May 2022
  '53aba266/player_ias.vflset/en_US/base' => '19121 w34 s1 r s1 r s3 r',# 09 May 2022
  '8a298c38/player_ias.vflset/en_US/base' => '19123 w14 w14 w18 w47 w21 w61 w42 w17 r',# 11 May 2022
  '00e475bf/player_ias.vflset/en_US/base' => '19124 w65 w31 r s2 r',# 12 May 2022
  '9c7ce883/player_ias.vflset/en_US/base' => '19128 w68 r w68 r s2 w39 s1',# 16 May 2022
  '3b04fdc7/player_ias.vflset/en_US/base' => '19130 w56 w46 s2 w46',# 18 May 2022
  'ec0ced91/player_ias.vflset/en_US/base' => '19131 r w66 w44 s2 w28 w67 s3',# 19 May 2022
  'c5a4daa1/player_ias.vflset/en_US/base' => '19135 w55 w18 w21 s1 w53',# 23 May 2022
  'd1783cbe/player_ias.vflset/en_US/base' => '19137 s3 r s1 w63', # 25 May 2022
  'c403842a/player_ias.vflset/en_US/base' => '19138 w54 s1 w18 s2 r s1 w6',# 26 May 2022
  '02208bb4/player_ias.vflset/en_US/base' => '19144 s3 r w48',    # 01 Jun 2022
  '966d033c/player_ias.vflset/en_US/base' => '19149 w50 s3 w64 w11 w42 w41 s2',# 06 Jun 2022
  'd97f25df/player_ias.vflset/en_US/base' => '19151 s1 w28 r s3 w24 w42 w44',# 08 Jun 2022
  '23010b46/player_ias.vflset/en_US/base' => '19152 w54 r s2 w65 w56 w53 s3 w4 s2',# 09 Jun 2022
  '5dedc3ae/player_ias.vflset/en_US/base' => '19156 w6 w21 r s2 r s2 w69 r s2',# 13 Jun 2022
  'df5197e2/player_ias.vflset/en_US/base' => '19157 w68 w11 w8 w38',# 14 Jun 2022
  'f05de49d/player_ias.vflset/en_US/base' => '19159 w21 s3 w6',   # 16 Jun 2022
  '9017ba60/player_ias.vflset/en_US/base' => '19166 r s3 w1 s1 w13 r s1',# 23 Jun 2022
  '9c24c545/player_ias.vflset/en_US/base' => '19167 w69 s3 r s2 r s1 w46 s3 r',# 24 Jun 2022
  '60c2da65/player_ias.vflset/en_US/base' => '19170 w3 s3 r s1',  # 27 Jun 2022
  'bc3f94c3/player_ias.vflset/en_US/base' => '19172 w69 r s1 w58 s2 r',# 29 Jun 2022
  '0e7373c2/player_ias.vflset/en_US/base' => '19173 r s3 w23 s3 r',# 30 Jun 2022
  '132602e8/player_ias.vflset/en_US/base' => '19184 s3 w11 s1 r w12 r w47',# 11 Jul 2022
  '17327fbd/player_ias.vflset/en_US/base' => '19186 w23 w30 s3 r',# 13 Jul 2022
  'dfd2e197/player_ias.vflset/en_US/base' => '19187 s3 r w55 s3 r s3 w48 w17 w43',# 14 Jul 2022
  '9504bca9/player_ias.vflset/en_US/base' => '19191 s3 r w70 w62 w44 s1',# 18 Jul 2022
  '011af516/player_ias.vflset/en_US/base' => '19193 r w25 r w16 s3 w16 r',# 20 Jul 2022
  'afeb58ff/player_ias.vflset/en_US/base' => '19194 r w20 w3 s2', # 21 Jul 2022
  '5784b7e4/player_ias.vflset/en_US/base' => '19198 w66 s2 w11',  # 25 Jul 2022
  '240bde48/player_ias.vflset/en_US/base' => '19200 s3 w48 r s2 r s3 r',# 27 Jul 2022
  'c8b8a173/player_ias.vflset/en_US/base' => '19201 w42 s3 w48 r',# 28 Jul 2022
  '7a7465f5/player_ias.vflset/en_US/base' => '19205 w12 s2 w62',  # 01 Aug 2022
  '7802ea37/player_ias.vflset/en_US/base' => '19207 s1 r s1 w28', # 03 Aug 2022
  '2fd212f2/player_ias.vflset/en_US/base' => '19208 w35 r s3 r w45 w42 s3 w18',# 04 Aug 2022
  '0d77e7db/player_ias.vflset/en_US/base' => '19212 w2 s1 r s3',  # 08 Aug 2022
  '4c3f79c5/player_ias.vflset/en_US/base' => '19215 s1 w50 s1 r w37 r',# 11 Aug 2022
  'c81bbb4a/player_ias.vflset/en_US/base' => '19219 w23 r s2 w63 s1 w37 w6 r',# 15 Aug 2022
  '1f7d5369/player_ias.vflset/en_US/base' => '19221 s2 w51 w36 r s2 r w15 w57',# 17 Aug 2022
  '009f1d77/player_ias.vflset/en_US/base' => '19222 w53 s1 r s1 w65 w61',# 18 Aug 2022
  '0c356943/player_ias.vflset/en_US/base' => '19226 r w10 w69 w6 r s3 w27 w47 s3',# 22 Aug 2022
  'dc0c6770/player_ias.vflset/en_US/base' => '19228 s1 r s2 w64 r w1 s1 w34',# 24 Aug 2022
  'c2199353/player_ias.vflset/en_US/base' => '19229 w68 r s1 r s2 w31 w21 r w65',# 25 Aug 2022
  '113ca41c/player_ias.vflset/en_US/base' => '19233 s3 r w23 r s3 r w14 r',# 29 Aug 2022
  'c57c113c/player_ias.vflset/en_US/base' => '19235 w29 r s1 w30 s2 r s2',# 31 Aug 2022
  '5a3b6271/player_ias.vflset/en_US/base' => '19236 r s3 r s3',   # 01 Sep 2022
  'c16db54a/player_ias.vflset/en_US/base' => '19237 r s2 r',      # 02 Sep 2022
  'a7eb1f5d/player_ias.vflset/en_US/base' => '19240 r w3 w60 r s1 w53 s2 w42 s1',# 05 Sep 2022
  'f96f6702/player_ias.vflset/en_US/base' => '19242 w30 s1 w26 w11 s2',# 07 Sep 2022
  '977792fa/player_ias.vflset/en_US/base' => '19243 w23 w36 s2 r s2 r',# 08 Sep 2022
  '92f199c8/player_ias.vflset/en_US/base' => '19247 r w36 r s2 r s2 r',# 12 Sep 2022
  'ec3f41f6/player_ias.vflset/en_US/base' => '19249 s3 w38 r w39 w37 r s1 w57',# 14 Sep 2022
  'a97e97de/player_ias.vflset/en_US/base' => '19250 r s2 w5 r',   # 15 Sep 2022
  '7577aaa2/player_ias.vflset/en_US/base' => '19254 w63 s1 r',    # 19 Sep 2022
  '64947e15/player_ias.vflset/en_US/base' => '19256 s1 r s3 r s2 r',# 21 Sep 2022
  'abfb84fe/player_ias.vflset/en_US/base' => '19257 w38 s3 w11 w34 w57',# 22 Sep 2022
  'bd1343fa/player_ias.vflset/en_US/base' => '19261 s2 r w65 r s1',# 26 Sep 2022
  '5248e50a/player_ias.vflset/en_US/base' => '19263 w68 w39 w16 w15 w61 w44',# 28 Sep 2022
  'a336babc/player_ias.vflset/en_US/base' => '19264 r w44 w7 s2', # 29 Sep 2022
  '374003a5/player_ias.vflset/en_US/base' => '19268 r s1 w41 r w41 s3 r w51',# 03 Oct 2022
  '55fdc514/player_ias.vflset/en_US/base' => '19270 w1 r s2 w15 s2',# 05 Oct 2022
  '17ab0793/player_ias.vflset/en_US/base' => '19271 r w52 w11 w25 w11 r s3 w49 s2',# 06 Oct 2022
  '7a062b77/player_ias.vflset/en_US/base' => '19275 w19 r s3 w32 w2 w31',# 10 Oct 2022
  'f11bc515/player_ias.vflset/en_US/base' => '19277 s1 r s1 w33 s1 w47 w44 s3 r',# 12 Oct 2022
  '1f77e565/player_ias.vflset/en_US/base' => '19278 w48 w43 s2 r s2 w39 w19 s1 r',# 13 Oct 2022
  'a25d4acf/player_ias.vflset/en_US/base' => '19282 w41 s1 r',    # 17 Oct 2022
  '24c6f8bd/player_ias.vflset/en_US/base' => '19284 w14 s1 r s3', # 19 Oct 2022
  '4bbf8bdb/player_ias.vflset/en_US/base' => '19285 r w6 w45 s3', # 20 Oct 2022
  '64588dad/player_ias.vflset/en_US/base' => '19291 w14 w14 r s2',# 26 Oct 2022
  '19fc75cf/player_ias.vflset/en_US/base' => '19292 r w52 w34',   # 27 Oct 2022
  '03bec62d/player_ias.vflset/en_US/base' => '19296 r s1 r w16 s2 r w29 w51',# 31 Oct 2022
  'c4225c42/player_ias.vflset/en_US/base' => '19303 w60 w56 w43 s3 w55',# 07 Nov 2022
  'b50b69c9/player_ias.vflset/en_US/base' => '19310 w55 r s2',    # 14 Nov 2022
  '6870f412/player_ias.vflset/en_US/base' => '19312 w42 s1 w23 r s3 w52 s2',# 16 Nov 2022
  '041a7965/player_ias.vflset/en_US/base' => '19313 s3 w43 r s1 w33 r',# 17 Nov 2022
);


my $cipher_warning_printed_p = 0;
sub decipher_sig($$$$$) {
  my ($url, $id, $cipher, $signature, $via) = @_;

  return $signature unless defined ($cipher);

  my $orig = $signature;
  my @s = split (//, $signature);

  my $c = $ciphers{$cipher};
  if (! $c) {
    print STDERR "$progname: WARNING: $id: unknown cipher $cipher\n"
      if ($verbose > 1 && !$cipher_warning_printed_p);
    $c = guess_cipher ($cipher, 0, $cipher_warning_printed_p);
    $ciphers{$cipher} = $c;
    $cipher_warning_printed_p = 1;
  }

  $c =~ s/([^\s])([a-z])/$1 $2/gs;
  my ($sts) = $1 if ($c =~ s/^(\d+)\s*//si);

  foreach my $c (split(/\s+/, $c)) {
    if    ($c eq '')           { }
    elsif ($c eq 'r')          { @s = reverse (@s);  }
    elsif ($c =~ m/^s(\d+)$/s) { @s = @s[$1 .. $#s]; }
    elsif ($c =~ m/^w(\d+)$/s) {
      my $a = 0;
      my $b = $1 % @s;
      ($s[$a], $s[$b]) = ($s[$b], $s[$a]);
    }
    else { errorI ("bogus cipher: $c"); }
  }

  $signature = join ('', @s);

  my $L1 = length($orig);
  my $L2 = length($signature);
  if ($verbose > 4 && $signature ne $orig) {
    print STDERR ("$progname: $id: translated sig, $sts $cipher:\n" .
                  "$progname:  old: $L1: $orig\n" .
                  "$progname:  new: $L2: $signature\n");
  }

  if (! ($signature =~ m/^[\dA-F]{30,}\.[\dA-F]{30,}$/s)) {
    $error_whiteboard .= ("$id: suspicious signature: $sts $cipher:\n" .
                          "$progname:  url: $url\n" .
                          "$progname:  via: $via\n" .
                          "$progname:  old: $L1: $orig\n" .
                          "$progname:  new: $L2: $signature\n");
  }

  return $signature;
}


sub page_cipher_base_url($$) {
  my ($url, $body) = @_;
  $body =~ s/\\//gs;
  # Sometimes but not always the "ux.js" file comes before "base.js".
  # But in the past, the file was not named "base.js"...
  # The proper document is the one that starts with "var _yt_player =".
  my ($c) = ($body =~ m@/jsbin/((?:html5)?player[-_][^<>\"\']+?/base)\.js@s);
     ($c) = ($body =~ m@/jsbin/((?:html5)?player[-_][^<>\"\']+?)\.js@s)
       unless defined($c);
     ($c) = ($body =~ m@/player/([^<>\"\']+/player[-_][^<>\"\']+/base)\.js@s)
       unless defined($c);

  $c =~ s@\\@@gs if defined($c);
  errorI ("matched wrong cipher: $c $url\nBody:\n$body")
    if (defined($c) && $c !~ m/base$/s);
  return $c;
}


# Total kludge that downloads the current html5player, parses the JavaScript,
# and intuits what the current cipher is.  Normally we go by the list of
# known ciphers above, but if that fails, we try and do it the hard way.
#
sub guess_cipher($;$$) {
  my ($cipher_id, $selftest_p, $nowarn) = @_;

  # If we're in cipher-guessing mode, crank up the verbosity to also
  # mention the list of formats and which format we ended up choosing.
  # $verbose = 2 if ($verbose == 1 && !$selftest_p);


  my $url = "https://www.youtube.com/";
  my ($http, $head, $body);
  my $id = '-';

  if (! $cipher_id) {
    ($http, $head, $body) = get_url ($url);   # Get home page
    check_http_status ('-', $url, $http, 2);

    my @vids = ();
    $body =~ s%/watch\?v=([^\"\'<>\s]+)%{
      push @vids, $1;
      '';
    }%gsex;

    errorI ("no  videos found on home page $url") unless @vids;

    # Get random video -- pick one towards the middle, because sometimes
    # the early ones are rental videos.
    my $id = @vids[int(@vids / 2)];
    $url .= "/watch\?v=$id";

    ($http, $head, $body) = get_url ($url); # Get random video's info
    check_http_status ($id, $url, $http, 2);

    ($cipher_id) = page_cipher_base_url ($url, $body);

    error ("$id: rate limited")
      if (!$cipher_id && $body =~ m/large volume of requests/);
    errorI ("$id: unparsable cipher url: $url\n\nBody:\n\n$body")
      unless $cipher_id;
  }

  $cipher_id =~ s@\\@@gs;
  $url = ($cipher_id =~ m/vflset/
          ? "https://www.youtube.com/s/player/$cipher_id.js"
          : "https://s.ytimg.com/yts/jsbin/$cipher_id.js");

  ($http, $head, $body) = get_url ($url);
  check_http_status ($id, $url, $http, 2);

  my ($date) = ($head =~ m/^Last-Modified:\s+(.*)$/mi);
  $date =~ s/^[A-Z][a-z][a-z], (\d\d? [A-Z][a-z][a-z] \d{4}).*$/$1/s;

  my $v  = '[\$a-zA-Z][a-zA-Z\d]*'; # JS variable, 1+ characters
  my $v2 = '[\$a-zA-Z][a-zA-Z\d]?'; # JS variable, 2 characters

  $v  = "$v(?:\.$v)?";   # Also allow "a.b" where "a" would be used as a var.
  $v2 = "$v2(?:\.$v2)?";


  # First, find the sts parameter:
  my ($sts) = ($body =~ m/\bsts:(\d+)\b/si);

  if (!$sts) {  # New way, 4-Jan-2020
    # Find "N" in this: var f=18264; a.fa("ipp_signature_cipher_killswitch")
    ($sts) = ($body =~
              m/$v = (\d{5,}) ; $v \("ipp_signature_cipher_killswitch"\) /sx);
  }

  if (!$sts) {  # New way, 15-Aug-2020
    ($sts) = ($body =~ m/signatureTimestamp[:=](\d{5,})/s);
  }

  errorI ("$cipher_id: no sts parameter: $url") unless $sts;


  # Since the script is minimized and obfuscated, we can't search for
  # specific function names, since those change. Instead we match the
  # code structure.
  #
  # Note that the obfuscator sometimes does crap like y="split",
  # so a[y]("") really means a.split("")


  # Find "C" in this: var A = B.sig || C (B.s)
  my (undef, $fn) = ($body =~ m/$v = ( $v ) \.sig \|\| ( $v ) \( \1 \.s \)/sx);

  # If that didn't work:
  # Find "C" in this: A.set ("signature", C (d));
  ($fn) = ($body =~ m/ $v \. set \s* \( "signature", \s*
                                        ( $v ) \s* \( \s* $v \s* \) /sx)
    unless $fn;

  # If that didn't work:
  # Find "C" in this: (A || (A = "signature"), B.set (A, C (d)))
  ($fn) = ($body =~ m/ "signature" \s* \) \s* , \s*
                       $v \. set \s* \( \s*
                       $v \s* , \s*
                       ( $v ) \s* \( \s* $v \s* \)
                     /sx)
    unless $fn;

  # Wow, what!  Convert (0,window.encodeURIComponent) to just w.eUC
  $body =~ s@\(0,($v)\)@ $1 @gs
    unless $fn;

  # If that didn't work:
  # Find "B" in this: A = B(C(A)), D(E,F(A))
  # Where "C" is "decodeURIComponent" and "F" is encodeURIComponent

  (undef, $fn) = ($body =~ m/ ( $v ) = ( $v ) \(   # A = B (
                              $v \( \1 \) \) ,     #  C ( A )),
                              $v \( $v ,           # D ( E,
                              $v \( $v \) \)       #  F ( A ))
                              /sx)
    unless $fn;

  # If that didn't work:
  # Find "C" in this: A.set (B.sp, D (C (E (B.s))))
  # where "D" is "encodeURIComponent" and "E" is "decodeURIComponent"
  # (Note, this rule is older than the above)

  ($fn) = ($body =~ m/ $v2 \. set \s* \( \s*    # A.set (
                       $v2 \s* , \s*            #   B.sp,
                       $v  \s* \( \s*           #   D (
                       ( $v2 ) \s* \( \s*       #     C (
                       $v  \s* \( \s*           #       E (
                       $v2 \s*                  #         B.s
                       \) \s* \) \s* \) \s* \)  #         ))))
                     /sx)
    unless $fn;

  # If that didn't work:
  # Find "C" in this: A.set (B, C (d))
  # or this: A.set (B.sp, C (B.s))
  ($fn) = ($body =~ m/ $v2 \. set \s* \( \s*
                       $v2 \s* , \s*
                       ( $v2 ) \s* \( \s* $v2 \s* \) \s* \)
                     /sx)
    unless $fn;


  errorI ("$cipher_id: unparsable cipher js: $url") unless $fn;
  # Congratulations! If the above error fired, start looking through $url
  # for a consecutive series of 2-arg function calls ending with a number.
  # The containing function is the decipherer, and its name goes in $fn.


  # Find body of function C(D) { ... }
  # might be: var C = function(D) { ... }
  # might be:   , C = function(D) { ... }
  my ($fn2) = ($body =~ m@\b function \s+ \Q$fn\E \s* \( $v \)
                          \s* { ( .*? ) } @sx);
     ($fn2) = ($body =~ m@(?: \b var \s+ | [,;] \s* )
                          \Q$fn\E \s* = \s* function \s* \( $v \)
                          \s* { ( .*? ) } @sx)
       unless $fn2;

  errorI ("$cipher_id: unparsable fn \"$fn\"") unless $fn2;

  $fn = $fn2;

  $error_whiteboard .= "fn: $fn2\n";

  # They inline the swapper if it's used only once.
  # Convert "var b=a[0];a[0]=a[63%a.length];a[63]=b;" to "a=swap(a,63);".
  $fn2 =~ s@
            var \s ( $v ) = ( $v ) \[ 0 \];
            \2 \[ 0 \] = \2 \[ ( \d+ ) % \2 \. length \];
            \2 \[ \3 \]= \1 ;
           @$2=swap($2,$3);@sx;

  my @cipher = ();
  foreach my $c (split (/\s*;\s*/, $fn2)) {

    # Typically the obfuscator gives member functions names like 'XX.YY',
    # but in the case where 'YY' happens to be a reserved word, like 'do',
    # it will instead emit 'XX["YY"]'.
    #
    $c =~ s@ ^ ( $v ) \[\" ( $v ) \"\] @$1.$2@sx;

    if      ($c =~ m@^ ( $v ) = \1 . $v \(""\) $@sx) {         # A=A.split("");
    } elsif ($c =~ m@^ ( $v ) = \1 .  $v \(\)  $@sx) {         # A=A.reverse();
      $error_whiteboard .= "fn: r: $1\n";
      push @cipher, "r";
    } elsif ($c =~ m@^ ( $v ) = \1 . $v \( (\d+) \) $@sx) {    # A=A.slice(N);
      $error_whiteboard .= "fn: s: $1\n";
      push @cipher, "s$2";

    } elsif ($c =~ m@^ ( $v ) = ( $v ) \( \1 , ( \d+ ) \) $@sx ||  # A=F(A,N);
             $c =~ m@^ (    )   ( $v ) \( $v , ( \d+ ) \) $@sx) {  # F(A,N);
      my $f = $2;
      my $n = $3;
      $f =~ s/^.*\.//gs;  # C.D => D
      # Find function D, of the form: C={ ... D:function(a,b) { ... }, ... }
      # Sometimes there will be overlap: X.D and Y.D both exist, and the
      # one we want is the second one. So assume the one we want is simple
      # enough to not contain any {} inside it.
      my ($fn3) = ($body =~ m@ \b \"? \Q$f\E \"? : \s*
                               function \s* \( [^(){}]*? \) \s*
                                ( \{ [^{}]+ \} )
                             @sx);
      if (!$fn3) {
        $fn =~ s/;/;\n\t    /gs;
        error ("unparsable: function \"$f\" not found\n\tin: $fn");
      }
      # Look at body of D to decide what it is.
      if ($fn3 =~ m@ var \s ( $v ) = ( $v ) \[ 0 \]; @sx) {  # swap
        $error_whiteboard .= "fn3: w: $f: $fn3\n";
        push @cipher, "w$n";
      } elsif ($fn3 =~ m@ \b $v \. reverse\( @sx) {          # reverse
        $error_whiteboard .= "fn3: r: $f: $fn3\n";
        push @cipher, "r";
      } elsif ($fn3 =~ m@ return \s* $v \. slice @sx ||      # slice
               $fn3 =~ m@ \b $v \. splice @sx) {             # splice
        $error_whiteboard .= "fn3: s: $f: $fn3\n";
        push @cipher, "s$n";
      } else {
        $fn =~ s/;/;\n\t    /gs;
        errorI ("unrecognized cipher body $f($n) = $fn3\n\tin: $fn");
      }
    } elsif ($c =~ m@^ return \s+ $v \. $v \(""\) $@sx) { # return A.join("");
    } else {
      $fn =~ s/;/;\n\t    /gs;
      errorI ("$cipher_id: unparsable: $c\n\tin: $fn");
    }
  }
  my $cipher = "$sts " . join(' ', @cipher);

  $error_whiteboard .= "cipher: $cipher\n";

  if ($selftest_p) {
    return $cipher if defined($ciphers{$cipher_id});
    $verbose = 2 if ($verbose < 2);
  }

  if ($verbose > 1 && !$nowarn) {
    my $c2 = "  '$cipher_id' => '$cipher',";
    $c2 = sprintf ("%-66s# %s", $c2, $date);
    auto_update($c2) if ($selftest_p && $selftest_p == 2);
    print STDERR "$progname: current cipher is:\n$c2\n";
  }

  return $cipher;
}


# Tired of doing this by hand. Crontabbed self-modifying code!
#
sub auto_update($) {
  my ($cipher_line) = @_;

  open (my $in, '<:raw', $progname0) || error ("$progname0: $!");
  local $/ = undef;  # read entire file
  my ($body) = <$in>;
  close $in;

  $body =~ s@(\nmy %ciphers = .*?)(\);)@$1$cipher_line\n$2@s ||
    error ("auto-update: unable to splice");

  # Since I'm not using CVS any more, also update the version number.
  $body =~ s@([\$]Revision:\s+\d+\.)(\d+)(\s+[\$])@
             { $1 . ($2 + 1) . $3 }@sexi ||
    error ("auto-update: unable to tick version");

  open (my $out, '>:raw', $progname0) || error ("$progname0: $!");
  syswrite ($out, $body) || error ("auto-update: $!");
  close $out;
  print STDERR "$progname: auto-updated $progname0\n";

  # This part isn't expected to work for you.
  my ($dir) = $ENV{HOME} . '/www/hacks';
  system ("cd '$dir'" .
          " && git commit -q -m 'cipher auto-update' '$progname'" .
          " && git push -q")
    if -d $dir;
}


# Replace the signature in the URL, deciphering it first if necessary.
#
sub apply_signature($$$$$$) {
  my ($id, $fmt, $url, $cipher, $sig, $via) = @_;
  if ($sig) {
    if (defined ($cipher)) {
      my $o = $sig;
      $sig = decipher_sig ($url, $fmt ? "$id/$fmt" : $id, $cipher, $sig, $via);
      if ($o ne $sig) {
        my $n = $sig;
        my ($a, $b) = split(/\./, $o);
        my ($c, $d) = split(/\./, $sig);
        ($a, $b) = ($o,   '') unless defined($b);
        ($c, $d) = ($sig, '') unless defined($d);
        my $L1 = sprintf("%d %d.%d", length($o),   length($a), length($b));
        my $L2 = sprintf("%d %d.%d", length($sig), length($c), length($d));
        foreach ($o, $n) { s/\./.\n          /gs; }
        my $s = "cipher:   $cipher\n$L1: $o\n$L2: $n";
#        $error_whiteboard .= "\n" if $error_whiteboard;
        $fmt = '?' unless defined($fmt);
#        $error_whiteboard .= "$fmt:       " .
#                             "https://www.youtube.com/watch?v=$id\n$s";
        if ($verbose > 3) {
          print STDERR "$progname: $id: deciphered and replaced signature\n";
          $s =~ s/^([^ ]+)(  )/$2$1/s;
          $s =~ s/^/$progname:    /gm;
          print STDERR "$s\n";
        }
      }
    }

    if ($url =~ m@^(.*)/s/[^/]+(.*)$@s) {
      $url = "$1/signature/$sig$2";  # DASH /s/ => /signature/
    } elsif ($url =~ m/\?/s) {
      # Default is to do "signature=SIG" but if there is "sp=XXX"
      # in the url_map, that means it goes in "XXX=SIG" instead
      # in the video URL.
      my ($sig_tag) = ($via =~ m/&sp=([^&]+)/s);
      $sig_tag = 'signature' unless defined($sig_tag);
      $url =~ s@ & ( signature | sig | \Q$sig_tag\E ) = [^&]+ @@gsx;
      $url .= '&' . $sig_tag . '=' . $sig;
    } else {
      errorI ("unable to splice signature: $url");
    }
  }
  return $url;
}




# Convert the text of a Youtube urlmap field into a structure.
# Apply signatures to enclosed URLs as necessary.
# Returns a hashref, or undef if the signatures could not be applied.
# If $into is provided, inserts the new items there, but does not overwrite
# existing ones.
#
# Returns the number of formats parsed (including redundant ones).
#
sub youtube_parse_urlmap($$$;$) {
  my ($id, $urlmap, $cipher, $into) = @_;

  my $cipher_printed_p = 0;

  if ($urlmap =~ m/^\{"/s) {      # Ugh, sometimes it is JSON
    $urlmap =~ s/^\{//s;

    # FFS, I don't want to write a whole JSON parser!
    # codecs=\"abc, def\"  ->  %2C
    $urlmap =~ s/(\\".*?\\")/{ my $s = $1; $s =~ s@,@%2C@gs; $s; }/gsexi;
    $urlmap =~ s/"( [^\"\[\],]*? )" :
                  ( [^,]+ ) [,\}]* / {    # "a":x, => a=x&
                 "$1=" . url_quote($2) . "&";
                }/gsexi;
    $urlmap =~ s/&\{/,/gs;
  }

  error ("video has not yet premiered")
    if ($urlmap =~ m/source=yt_premiere_broadcast/gs);

  my $count = 0;
  foreach my $mapelt (split (/,/, $urlmap)) {
    # Format used to be: "N|url,N|url,N|url"
    # Now it is: "url=...&quality=hd720&fallback_host=...&type=...&itag=N"
    my ($k, $v, $e, $sig, $sig2, $sig3, $w, $h, $size);
    my $sig_via = $mapelt;

    if ($mapelt =~ m/^\d+\|/s) {
      ($k, $v) = m/^(.*?)\|(.*)$/s;
    } elsif ($mapelt =~ m/^[a-z][a-z\d_]*=/s) {

      ($sig)  = ($mapelt =~ m/\bsig=([^&]+)/s); # sig= when un-ciphered.
      ($sig2) = ($mapelt =~ m/\bs=([^&]+)/s); # s= when enciphered.
      ($sig3) = ($mapelt =~ m@/s/([^/?&]+)@s);  # /s/XXX/ in DASH.

      ($k) = ($mapelt =~ m/\bitag=(\d+)/s);
      ($v) = ($mapelt =~ m/\burl=([^&]+)/s);
      $v = '' unless $v;

      # In JSON, "cipher":"sp=sig&s=...&url=..."
      if ($mapelt =~ m@\b(cipher|signatureCipher)=([^&\"{}]+)@s) {
        my $sig4 = url_unquote ($2);
        $sig4 =~ s/^.*"(.*?)".*$/$1/s;
        $sig4 =~ s@\\u0026@&@gs;
        my ($s2)  = ($sig4 =~ m/\bs=([^&]+)/s);
        my ($u2)  = ($sig4 =~ m/\burl=([^&]+)/s);
        if ($u2) {
          $sig  = undef;
          $sig2 = $s2;
          $v    = $u2;
          $sig_via = $sig4;  # so that apply_signature can find sp=
        }
      }

      $v =~ s@\\u0026@&@gs;
      $v = url_unquote($v);
      $v =~ s/^\"|\"$//gs;

      ($size)  = ($v =~ m/\bclen=([^&]+)/s);
      ($w, $h) = ($v =~ m/\bsize=(\d+)x(\d+)/s);

      # JSON
      ($size)  = ($mapelt =~ m/\bcontentLength=\"?(\d+)/s) unless $size;
      ($w) = ($mapelt =~ m/\bwidth=\"?(\d+)/s)  unless $w;
      ($h) = ($mapelt =~ m/\bheight=\"?(\d+)/s) unless $h;

      my ($q) = ($mapelt =~ m/\bquality=([^&]+)/s);
      my ($t) = ($mapelt =~ m/\b(?:type|mimeType)=([^&]+)/s);
      $q = url_unquote($q) if ($q);
      $t = url_unquote($t) if ($t);
      if ($q && $t) {
        $e = "\t$q, $t";
      } elsif ($t) {
        $e = $t;
      }
      $e = url_unquote($e) if ($e);
    }

#    error ("$id: can't download RTMPE DRM videos")
#      # There was no indiciation in get_video_info that this is an RTMPE
#      # stream, so it took us several retries to fail here.
#      if (!$v && $urlmap =~ m/\bconn=rtmpe%3A/s);

    #next unless ($k && $v);
    errorI ("$id: unparsable urlmap entry: no itag: $mapelt") unless ($k);
    errorI ("$id: unparsable urlmap entry: no url: $mapelt")  unless ($v);

    my ($ct) = ($e =~ m@\b((audio|video|text|application)/[-_a-z\d]+)\b@si);

    # Youtube has started returning "video/mp4" content types that are
    # actually VP9 / WebM rather than H.264. Those must be transcoded,
    # not copied, to play on H.264-only devices.
    #
    if ($e =~ m@\b(vp9)\b@si) {   # video/mp4; codecs="vp9"
      $ct = 'video/webm';
    } elsif ($e =~ m@(av1|av01)@si) { # video/mp4; codecs="av01.0.16M.08"
      $ct = 'video/av1';
    } elsif ($e =~ m@\b(opus)\b@si) { # audio/mp4; codecs="opus"
      $ct = 'audio/opus';
    }

    $v =~ s@^.*?\|@@s;  # VEVO

    $v =~ s@\\u0026@&@gs;  # FFS

    errorI ("$id: enciphered URL but no cipher found: $v")
      if (($sig2 || $sig3) && !$cipher);

    if ($verbose > 1 && !$cipher_printed_p) {
      print STDERR "$progname: $id: " .
                   (($sig2 || $sig3) ? "enciphered" : "non-enciphered") .
                   (($sig2 || $sig3) ? " (" . ($cipher || 'NONE') . ")" :
                    ($cipher ? " ($cipher)" : "")) .
                   "\n";
      $cipher_printed_p = 1;
    }

    # Apply the signature to the URL, deciphering it if necessary.
    #
    # The "use_cipher_signature" parameter is as lie: it is sometimes true
    # even when the signatures are not enciphered.  The only way to tell
    # is if the URLs in the map contain "s=" instead of "sig=".
    #
    # If we loaded get_video_info with the "sts" parameter, meaning we told
    # it what cipher to use, then the returned URLs have that cipher, and
    # all is good.  However, if we had omitted the "sts" parameter, then
    # the URLs come back with some unknown cipher (it's not the last cipher
    # in the list, for example) so we can't decode it.
    #
    # So in the bad old days, we didn't use "sts", and when we got an
    # enciphered video, we had to scrape the HTML to find the real cipher.
    # This had the shitty side effect that when a video was both enciphered
    # and was "content warning", we couldn't download it at all.
    #
    # But now that we always pass "sts" to get_video_info, this isn't a
    # problem any more.  I think that in this modern world, we never actually
    # need to scrape HTML any more, because we should always know a working
    # cipher ahead of time.
    #
    # Aug 2018: Nope, we now scrape HTML every time because that's the only
    # way to reliably get dashmpd URLs that work.
    #
    $v = apply_signature ($id, $k, $v,
                          ($sig2 || $sig3) ? $cipher : undef,
                          url_unquote ($sig || $sig2 || $sig3 || ''),
                          $sig_via);

    # Finally! The "ratebypass" parameter turns off rate limiting!
    # But we can't add it to a URL that signs the "ratebypass" parameter.
    #
    if (! ($v =~ m@sparams=[^?&]*ratebypass@ ||
           $v =~ m@sparams/[^/]*ratebypass@)) {
      if ($v =~ m@\?@s) {
        $v .= '&ratebypass=yes';
      } elsif ($v =~ m@/itag/@s) {   # dashmpd-style.
        $v .= ($v =~ m@/$@s ? '' : '/') . 'ratebypass/yes/';
      }
    }

    print STDERR "\t\t$k\t$v\t$e\n" if ($verbose > 3);

    if ($v =~ m/&live=(1|yes)\b/gs) {
      # We need to get the segments from the DASH manifest instead:
      # this URL is only the first segment, a few seconds long.
      print STDERR "$progname: $id: skipping fmt $k\n" if ($verbose > 2);
      next;
    }

    my %v = ( fmt  => $k,
              url  => $v,
              content_type => $ct,
              w => $w,
              h => $h,
              size => $size,
            );

    if (! defined ($into->{$k})) {
      $into->{$k} = \%v;
      print STDERR "$progname: $id: found fmt $k\n" if ($verbose > 2);
    }

    $count++;
  }

  return $count;
}


# There are two ways of getting the underlying video formats from youtube:
# parse it out of the HTML, or call get_video_info.
#
# We have to do both, because they all fail in different ways at different
# times, so we try a bunch of things and append together any results we find.
# The randomness leading to this crazy approach includes but is not limited
# to:
#
#  - The DASH URL in the HTML always works, but sometimes the DASH URL in
#    get_video_info does not -- the latter appears to use a different cipher.
#
#  - There are 4 different ways of invoking get_video_info, and sometimes
#    only one of them works. E.g., sometimes the "el=" option is needed to
#    retrieve info, but sometimes it *prevents* you from retrieving info.
#    E.g., "info" and "embedded" sometimes give geolocation errors, and
#    yet are the only way to bypass the age gate.
#
#  - Sometimes all formats are present in get_video_info, but sometimes only
#    the 720p and lower resolutions are there, and higher resolutions are
#    only listed in the DASH URL.
#
#  - Sometimes the DASH URL pointed to from the HTML and the DASH URL pointed
#    to by get_video_info have different sets of formats in them.
#
#  - And sometimes there are no DASH URLs.


# Sep 2021: It no longer seems possible to get video formats of age-restricted
# videos. There's a new replacement for get_video_info that looks like this:
#
#   POST to https://www.youtube.com/youtubei/v1/player?key=$key
#   with: { "context": {
#             "client": { "hl": "en", "clientName": "WEB",
#                         "clientVersion": "[$vv]",
#                         "mainAppWebInfo": { "graftUrl": "/watch?v=$vid" }}},
#           "videoId": "$vid" }
#
# But that doesn't return underlying formats for age-restricted videos either.



# Parses a dashmpd URL and inserts the contents into $fmts
# as per youtube_parse_urlmap.
#
sub youtube_parse_dashmpd($$$$) {
  my ($id, $url, $cipher, $into) = @_;

  # I don't think this is needed.
  # $url .= '?disable_polymer=true';

  # Some dashmpd URLs have /s/NNNNN.NNNNN enciphered signatures in them.
  # We have to replace them with /signature/MMMMM.MMMMM or we can't read
  # the manifest file. The URLs *within* the manifest will also have
  # signatures on them, but ones that (I think?) do not need to be
  # deciphered.
  #
  if ($url =~ m@/s/([^/]+)@s) {
    my $sig = $1;
    print STDERR "$id: DASH manifest enciphered\n" if ($verbose > 1);
    $url = apply_signature ($id, undef, $url, $cipher, $sig, '');
    print STDERR "$id: DASH manifest deciphered\n" if ($verbose > 1);
  } else {
    print STDERR "$id: DASH manifest non-enciphered\n" if ($verbose > 1);
  }

  my $count = 0;
  my ($http2, $head2, $body2) = get_url ($url);
  check_http_status ($id, $url, $http2, 2);

  # Nuke the subtitles: the Representations inside them aren't useful.
  $body2 =~ s@<AdaptationSet mimeType=[\"\']text/.*?</AdaptationSet>@@gs;

  my ($mpd) = ($body2 =~ m@<MPD\b([^<>]*)>@si);
  error ("no MPD in DASH $url") unless $mpd;
  if ($mpd =~ m@\btype=[\"\']dynamic[\"\']@si) {
    # default: type="static"
    # The stream is live, and there will be some arbitrary (possibly large)
    # number of segments, but that's not the whole thing. Punt.
    print STDERR "$progname: DASH is a live stream: $url\n"
      if ($verbose > 2);
    return 0;
  }

  my @reps = split(/<Representation\b/si, $body2);
  shift @reps;
  foreach my $rep (@reps) {
    my ($k)    = ($rep =~ m@id=[\'\"](.+?)[\'\"]@si);
    my ($url)  = ($rep =~ m@<BaseURL\b[^<>]*>([^<>]+)@si);
    my ($type) = ($rep =~ m@\bcodecs="(.*?)"@si);
    my ($w)    = ($rep =~ m@\bwidth="(\d+)"@si);
    my ($h)    = ($rep =~ m@\bheight="(\d+)"@si);
    my ($segs) = ($rep =~ m@<SegmentList[^<>]*>(.*?)</SegmentList>@si);
    my $size;
    $type = ($w && $h ? "video/mp4" : "audio/mp4") . ";+codecs=\"$type\"";

    if ($segs) {
      my ($url0) = ($segs =~ m@<Initialization\s+sourceURL="(.*?)"@si);
      my @urls = ($segs =~ m@<SegmentURL\s+media="(.*?)"@gsi);
      unshift @urls, $url0 if defined($url0);
      foreach (@urls) { $_ = $url . $_; };
      $url = \@urls;

      ($size) = ($url0 =~ m@/clen/(\d+)/@si)  # Not always present
        if ($url0);
    }

    my %v = ( fmt => $k,
              url => $url,
              content_type => $type,
              dashp => 1,
              w => $w,
              h => $h,
              size => $size,
              # abr  => undef,
            );

    # Sometimes the DASH URL for a format works but the non-DASH URL is 404.
    my $prefer_dash_p = 1;
    my $old = $into->{$k};
    $old = undef if ($prefer_dash_p && $old && !$old->{dashp});
    if (!$old) {
      $into->{$k} = \%v;
      print STDERR "$progname: $id: found fmt $k" .
            (ref($url) eq 'ARRAY' ? " (" . scalar(@$url) . " segs)" : "") .
            "\n"
        if ($verbose > 2);
    }
    $count++;
  }

  return $count;
}


# For some errors, we know there's no point in retrying.
#
my $blocked_re = join ('|',
                       ('(available|blocked it) in your country',
                        'copyright (claim|grounds)',
                        'removed by the user',
                        'account.*has been terminated',
                        'has been removed',
                        'has not made this video available',
                        'has closed their YouTube account',
                        'is not available',
                        'is unavailable',
                        'video unavailable',
                        'video does not exist',
                        'is not embeddable',
                        'can\'t download rental videos',
                        'livestream videos',
                        'invalid parameters',
                        'RTMPE DRM',
                        'Private video\?',
                        'video is private',
                        'piece of shit',
                        'you are a human',
                        '\bCAPCHA required',
                        '\b429 Too Many Requests',
                        'Premieres in \d+ (min|hour|day|week|month)',
                        'video has not yet premiered',
                        'live event will begin in',
                        'live event has ended',
                        '^[^:]+: exists: ',
                        'no pre-muxed format',
                        # Muxer failures are permanently fatal
                        '^([^\s:]+: )?ffmpeg: ',
                       ));


# Scrape the HTML page to extract the video formats.
# Populates $fmts and returns $error_message.
#
sub load_youtube_formats_html($$$) {
  my ($id, $url, $fmts) = @_;

  my $oerror = '';
  my $err = '';

  my ($http, $head, $body) = get_url ($url);

  my ($title) = ($body =~ m@<title>\s*(.*?)\s*</title>@si);
  $title = '' unless $title;
  utf8::decode ($title);  # Pack multi-byte UTF-8 back into wide chars.
  $title = munge_title (html_unquote ($title));
  # Do this after we determine whether we have any video info.
  # sanity_check_title ($title, $url, $body, 'load_youtube_formats_html');

  get_youtube_year ($id, $body);  # Populate cache so we don't load twice.

  my $unquote_p = 1;
  my ($args) = ($body =~ m@'SWF_ARGS' *: *{(.*?)}@s);

  if (! $args) {    # Sigh, new way as of Apr 2010...
    ($args) = ($body =~ m@var swfHTML = [^\"]*\"(.*?)\";@si);
    $args =~ s@\\@@gs if $args;
    ($args) = ($args =~ m@<param name="flashvars" value="(.*?)">@si) if $args;
    ($args) = ($args =~ m@fmt_url_map=([^&]+)@si) if $args;
    $args = "\"fmt_url_map\": \"$args\"" if $args;
  }
  if (! $args) {    # Sigh, new way as of Aug 2011...
    ($args) = ($body =~ m@'PLAYER_CONFIG':\s*{(.*?)}@s);
    $args =~ s@\\u0026@&@gs if $args;
    $unquote_p = 0;
  }
  if (! $args) {    # Sigh, new way as of Jun 2013...
    ($args) = ($body =~ m@ytplayer\.config\s*=\s*{(.*?)};@s);
    $args =~ s@\\u0026@&@gs if $args;
    $unquote_p = 1;
  }
  $args = '' unless defined $args;

  if (! $args) {
    # Try to find a better error message
    (undef, $err) = ($body =~ m@<( div | h1 ) \s+
                                    (?: id | class ) = 
                                   "(?: error-box |
                                        unavailable-message )"
                                   [^<>]* > \s*
                                   ( .+? ) \s*
                                    </ \1 > @six);
    if ($err) {
      $err =~ s@^.*="yt-uix-button-content"[^<>]*>([^<>]+).*@$1@si;
      $err =~ s/<[^<>]*>//gs;
    }

    $err = "Rate limited: CAPCHA required"
      if (!$err && $body =~ m/large volume of requests/);
    if ($err) {
      my ($err2) = ($body =~ m@<div class="submessage">(.*?)</div>@si);
      if ($err2) {
        $err2 =~ s@<button.*$@@s;
        $err2 =~ s/<[^<>]*>//gs;
        $err .= ": $err2";
      }
      $err =~ s/^"[^\"\n]+"\n//s;
      $err =~ s/^&quot;[^\"\n]+?&quot;\n//s;
      $err =~ s/\s+/ /gs;
      $err =~ s/^\s+|\s+$//s;
      $err =~ s/\.(: )/$1/gs;
      $err =~ s/\.$//gs;

      #$err = "$err ($title)" if ($title);

      $oerror = $err;
      $http = 'HTTP/1.0 404';
    }
  }

  # Sometimes we have <TITLE>YouTube</TITLE> but the real title is
  # buried inside some JSON.
  #
  if (!$title || $title =~ m/^untitled$/si) {
    if ($body =~ m/\\?"title\\?":\\?"(.*?)\\?",/si) {
      $title = $1;
      $title = munge_title (html_unquote ($title));
    }
  }

  $oerror =~ s@<.*?>@@gs if $oerror;

  $oerror =~ s/ \(YouTube\)$//s if $oerror;

  # Sometimes Youtube returns HTTP 404 pages that have real messages in them,
  # so we have to check the HTTP status late. But sometimes it doesn't return
  # 404 for pages that no longer exist. Hooray.

  $http = 'HTTP/1.0 404'
    if ($oerror && $oerror =~ m/$blocked_re/sio);
  $err = "$http: $oerror"
    unless (check_http_status ($id, $url, $http, 0));
  $err = "no ytplayer.config$oerror"
    if (!$args && !$err);

  if (!$err &&
      $body =~ m@"LIVE_STREAM_OFFLINE","reason":"(Premieres[^\"]+)@s) {
    $err = $1;
    $args = '';
  }

  my ($cipher) = page_cipher_base_url ($url, $body);

  my ($kind, $kind2, $urlmap, $urlmap2);

  #### hlsvp are m3u8u files, but that data always seems to also be present
  #### in dash, so I haven't bothered parsing those.

  my $count = 0;
  foreach my $key (#'hlsvp',
                   'fmt_url_map',
                   'fmt_stream_map', # VEVO
                   'url_encoded_fmt_stream_map', # Aug 2011
                   'adaptive_fmts',
                   'dashmpd',
                   'player_response',
    ) {
    my ($v) = ($args =~ m@"$key": *"(.*?[^\\])"@s);
    $v = '' if (!defined($v) || $v eq '",');
    $v =~ s@\\@@gs;
    next unless $v;
    print STDERR "$progname: $id HTML: found $key\n" if ($verbose > 2);

    # source%3Dyt_premiere_broadcast%26 or /source/yt_premiere_broadcast/
    if ($v =~ m/yt_premiere_broadcast/) {
      $err = "video has not yet premiered";
      undef %$fmts;  # The fmts point to a countdown video.
      last;
    }

    if ($v =~ m@&live_playback=([^&]+)@si ||
        $v =~ m@&live=(1)@si ||
        $v =~ m@&source=(yt_live_broadcast)@si ||
        $v =~ m@"status":"LIVE_STREAM_OFFLINE"@si) {
      $err = "can't download live videos";
      # The fmts point to an M3U8 that is currently of unbounded length.
      undef %$fmts;
      last;
    }

    if ($key eq 'dashmpd' || $key eq 'hlsvp') {
      my $n = youtube_parse_dashmpd ("$id HTML", $v, $cipher, $fmts);
      $count += $n;
      $err = "can't download live videos" if ($n == 0 && !$err);

    } elsif ($key eq 'player_response') {
      my $ov = $v;
      ($v) = ($ov =~ m@"dashManifestUrl": *"(.*?[^\\])"@s);
      # This manifest sometimes works when the one in get_video_info doesn't.
      if ($v) {
        my $n = youtube_parse_dashmpd ("$id HTML", $v, $cipher, $fmts);
        $count += $n;
        $err = "can't download live videos" if ($n == 0 && !$err);
      }

      # Nov 2019: Saw this on an old fmt 133 video, and it was the only
      # list of formats available in the HTML.
      ($v) = ($ov =~ m@"adaptiveFormats": *\[(.*?)\]@s);
      $count += youtube_parse_urlmap ("$id HTML", $v, $cipher, $fmts) if $v;

    } else {
      $count += youtube_parse_urlmap ("$id HTML", $v, $cipher, $fmts);
    }
  }

  # Sometimes none of that bullshit exists, but we have 
  # var ytInitialPlayerResponse = { ...
  # with formats, adaptiveFormats, and dashManifestUrl.
  #
  foreach my $key ('formats', 'adaptiveFormats') {
    my ($v) = ($body =~ m@"$key": *\[(\{.*?\})\]@s);
    $count += youtube_parse_urlmap ("$id HTML b", $v, $cipher, $fmts) if ($v);
  }
  my ($v) = ($body =~ m@"dashManifestUrl": *"(.*?[^\\])"@s);
  $count += youtube_parse_dashmpd ("$id HTML b", $v, $cipher, $fmts) if ($v);


  # Do this after we determine whether we have any video info.
  sanity_check_title ($title, $url,
                      "ERR: \"$err\"\n\n$body", ####
                      'load_youtube_formats_html')
    if ($count);


  $fmts->{title}  = $title  unless defined($fmts->{title});
  $fmts->{cipher} = $cipher unless defined($fmts->{cipher});
  return $err;
}


# Loads various versions of get_video_info to extract the video formats.
# Populates $fmts and returns $error_message.
#
sub load_youtube_formats_video_info($$$) {
  my ($id, $url, $fmts) = @_;

  my $cipher = $fmts->{cipher};
  my $sts = undef;

  if ($cipher) {
    my $c = $ciphers{$cipher};
    if (! $c) {
      print STDERR "$progname: WARNING: $id: unknown cipher $cipher\n"
        if ($verbose > 1 && !$cipher_warning_printed_p);
      $c = guess_cipher ($cipher, 0, $cipher_warning_printed_p);
      $ciphers{$cipher} = $c;
    }
    $sts = $1 if ($c =~ m/^\s*(\d+)\s/si);
    errorI ("$id: $cipher: no sts") unless $sts;
  }

  my $info_url_1 = ('https://www.youtube.com/get_video_info' .
                    "?video_id=$id" .
                    ($sts ? '&sts=' . $sts : '') .

                    # I don't think any of these are needed.
                    # '&ps=default' .
                    # '&hl=en' .
                    # '&disable_polymer=true' .
                    # '&gl=US' .

                    # Avoid "playback restricted" or "content warning".
                    # They sniff this referer for embedding.
                    '&eurl=' .
                    url_quote ('https://youtube.googleapis.com/v/' . $id)
                   );

  # Sometimes the 'el' arg is needed to avoid "blocked it from display
  # on this website or application". But sometimes, including it *causes*
  # "sign in to confirm your age". So try it with various options.
  #
  # Note that each of these can return a different error message for the
  # same unloadable video, so arrange them with better error last:
  #
  #   "":         "This video is unavailable"
  #   embedded:   "This video is unavailable"
  #   info:       "Invalid parameters"
  #   detailpage: "This video has been removed by the user"
  #
  my @extra_parameters = ('', '&el=embedded', '&el=info', '&el=detailpage');

  my ($title, $body, $embed_p, $rental, $live_p, $premiere_p);

  my $err = undef;
  my $done = 0;

  # The retries here are because sometimes we get HTTP 200, but the body
  # of the document contains fewer parameters than it should; reloading
  # sometimes fixes it.

#  my $retries = 5;
  my $retries = 1;
  while ($retries--) {
    foreach my $extra (@extra_parameters) {

      my $info_url = $info_url_1 . $extra;

      my ($http, $head);
      ($http, $head, $body) = get_url ($info_url);
      my $err2 = (check_http_status ($id, $url, $http, 0) ? undef : $http);
      $err = $err2 unless $err;

      my $body2 = $body;    # FFS
      $body2 =~ s/%5C/\\/gs;
      $body2 =~ s/\\u0026/&/gs;
      $body2 =~ s/%3D/=/gs;

      my ($prep) = ($body2 =~ m@&player_response=([^&]+)@si);
      $prep = url_unquote ($prep || '');

      ($title)    = ($body2 =~ m@&title=([^&]+)@si) unless $title;
      ($rental)   = ($body2 =~ m@&ypc_vid=([^&]+)@si);
      ($live_p)   = ($body2 =~ m@&live_playback=([^&]+)@si ||
                     $body2 =~ m@&live=(1)@si ||
                     $body2 =~ m@&source=(yt_live_broadcast)@si ||
                     $prep =~ m@"is_viewed_live","value":"True"@si);

      $embed_p = $1 if ($body =~ m@&allow_embed=([^&]+)@si);
      $embed_p = 0 if (!defined($embed_p) &&
                       ($body =~ m/on[+\s+]other[+\s+]websites/s ||
                        $body =~ m/Age.restricted/si));

      # Sigh, %2526source%253Dyt_premiere_broadcast%2526
      $premiere_p = 1 if ($body =~ m@yt_premiere_broadcast@s);

      $err = "can't download livestream videos" if ($live_p);
      # "player_response" contains JSON:
      #   "playabilityStatus":{
      #     "status":"LIVE_STREAM_OFFLINE",
      #     "reason":"Premieres in 10 hours",

      my $count = 0;
      foreach my $key (#'hlsvp',
                       'fmt_url_map',
                       'fmt_stream_map', # VEVO
                       'url_encoded_fmt_stream_map', # Aug 2011
                       'adaptive_fmts',
                       'dashmpd',
                       'player_response',
        ) {
        my ($v) = ($body =~ m@[?&]$key=([^&?]+)@si);
        next unless defined ($v);
        $v = url_unquote ($v);
        $v =~ s@\\u0026@&@gs;
        $v =~ s@\\@@gs;

        print STDERR "$progname: $id VI: found $key" .
                     (defined($embed_p)
                      ? ($embed_p ? " (embeddable)" : " (non-embeddable)")
                      : "") .
                     "\n"
          if ($verbose > 1);
        if ($key eq 'dashmpd' || $key eq 'hlsvp') {
          my $n = youtube_parse_dashmpd ("$id VI-1", $v, $cipher, $fmts);
          $count += $n;
          $err = "can't download live videos" if ($n == 0 && !$err);

        } elsif ($key eq 'player_response') {
          ($v) = ($v =~ m@"adaptiveFormats":\[(.*?)\]@s);
          $count += youtube_parse_urlmap ("$id VI-2", $v, $cipher, $fmts)
            if ($v);
        } else {
          $count += youtube_parse_urlmap ("$id VI-3", $v, $cipher, $fmts);
        }
      }

      $done = ($count >= 3 && $title);

      # Don't let "Invalid parameters" override "This video is private".
      $err = url_unquote ($1)
        if ((!$err || $err =~ m/invalid param/si) &&
            $body =~ m/\bstatus=fail\b/si &&
            $body =~ m/\breason=([^?&]+)/si);

      # This gets us "This video is private" instead of "Invalid parameters".
      if ($body =~ m/player_response=([^&]+)/s) {
        my $s = url_unquote ($1);
        $s =~ s@\\u0026@&@gs;
        $s =~ s@\\u003c@<@gs;
        $s =~ s@\\u003e@>@gs;
        $s =~ s@\\n@ @gs;
        if ($s =~ m/"reason":"(.*?)"[,\}]/si) {
          $err = $1;
          $err =~ s/<[^<>]*>//gs;
        }
      }
    }
    last if $done;
    sleep (1);
  }

  if ($err) {
    $err =~ s/<[^<>]+>//gs;
    $err =~ s/\n/ /gs;
    $err =~ s/\s*Watch on YouTube\.?//gs; # FU
  }

  $err = "video is not embeddable"
    if ($err && (defined($embed_p) && !$embed_p));

  if ($premiere_p) {
    $err = "video has not yet premiered";
    undef %$fmts if ($premiere_p);  # The fmts point to a countdown video.
  }

  $body = '' unless $body;
  ($title) = ($body =~ m@&title=([^&]+)@si) unless $title;
  errorI ("$id: no title in $info_url_1") if (!$title && !$err);
  $title = url_unquote($title) if $title;

  if (!$err) {
    ($err) = ($body =~ m@reason=([^&]+)@s);
    $err = '' unless $err;
    if ($err) {
      $err = url_unquote($err);
      $err =~ s/^"[^\"\n]+"\n//s;
      $err =~ s/\s+/ /gs;
      $err =~ s/^\s+|\s+$//s;
      $err = " (\"$err\")";
    }
  }

  $err =~ s/ \(YouTube\)$//s if $err;

  $err .= ': rental video' if ($err && $rental);

  if ($err && $rental) {
    error ("can't download rental videos, but the preview can be\n" .
           "$progname: downloaded at " .
           "https://www.youtube.com/watch?v=$rental");
  }

  utf8::decode ($title) if $title;
  $fmts->{title}  = $title  unless defined($fmts->{title});
  $fmts->{cipher} = $cipher unless defined($fmts->{cipher});

  return $err;
}


# Returns a hash of:
#  [ title => "T",
#    N => [ ...video info... ],
#    M => [ ...video info... ], ... ]
#
sub load_youtube_formats($$$) {
  my ($id, $url, $size_p) = @_;

  my %fmts;

  # I don't think any of these are needed.
  # $url .= join('&',
  #              'has_verified=1',
  #              'bpctr=9999999999',
  #              'hl=en',
  #              'disable_polymer=true');

  my $ping_p = (($size_p || 0) eq 'ping');

  # Scrape the HTML page first, or video info first?
  #
  #  - I have sometimes seen that the HTML page has a DASH URL that works,
  #    but get_video_info has one whose URLs are all 404 (early 2020).
  #  - I have sometimes seen the opposite. (Late 2020).
  #
  # So, let's alternate it on error retries.
  #
  my $html_first_p = !($total_retries & 1);

  my ($err1, $err2);
  if ($ping_p && $total_retries == 0) {
    $err1 = load_youtube_formats_video_info ($id, $url, \%fmts);
  } elsif ($html_first_p) {
    $err1 = load_youtube_formats_html       ($id, $url, \%fmts);
    $err2 = load_youtube_formats_video_info ($id, $url, \%fmts);
  } else {
    $err1 = load_youtube_formats_video_info ($id, $url, \%fmts);
    $err2 = load_youtube_formats_html       ($id, $url, \%fmts);
  }

  # Which error sucks less? Hard to say.
  # my $err = $err2 || $err;
  my $err = $err2 || $err1;
  $err = $err1 if ($err1 =~ m/premiere/si);

  my $both = ($err1 || '') . ' ' . ($err2 || '');
  $err = 'age-restricted video is not embeddable'
    if ($both =~ m/content warning/si &&
        $both =~ m/not embeddable/si);

  # It's rare, but there can be only one format available.
  # Keys: 18, cipher, title.

  undef %fmts if ($ping_p && $err =~ m/embeddable/si);

  if (scalar (keys %fmts) < 3) {
    error ("$id: $err") if $err;
    errorI ("$id: no formats available: $err");
  }

  $fmts{thumb} = "https://img.youtube.com/vi/" . $id . "/0.jpg"
    unless ($fmts{thumb});

  return \%fmts;
}


# Returns a hash of:
#  [ title: "T",
#    N: [ ...video info... ],
#    M: [ ...video info... ], ... ]
#
sub load_vimeo_formats($$$) {
  my ($id, $url, $size_p) = @_;

  # Vimeo's new way, 3-Mar-2015.
  # The "/NNNN?action=download" page no longer exists. There is JSON now.

  # This URL is *often* all that we need:
  #
  my $info_url = ("https://player.vimeo.com/video/$id/config" .
                  "?bypass_privacy=1");  # Not sure if this does anything

  # But if we scrape the HTML page for the version of the config URL
  # that has "&s=XXXXX" on it (some kind of signature, I presume) then
  # we *sometimes* get HD when we would not have gotten it with the
  # other URL:
  #
  my ($http, $head, $body) = get_url ($url);
  # Don't check status: sometimes the info URL is on the 404 page!
  # Maybe this happens if embedding is disabled.

  if ($body =~ m@([^<>.:]*verify that you are a human[^<>.:]*)@si) {
    error ("$id: $http $1");  # Bail early: $info_url will not succeed.
  }

  my $obody = $body;  # Might be a better error message in here.

  $body =~ s/\\//gs;
  if ($body =~ m@(\bhttps?://[^/]+/video/\d+/config\?[^\s\"\'<>]+)@si) {
    $info_url = html_unquote($1);
  } else {
    print STDERR "$progname: $id: no info URL\n" if ($verbose > 1);
  }

  my $referer = $url;

  # Test cases:
  #
  #   https://vimeo.com/120401488
  #     Has a Download link on the page that lists 270p, 360p, 720p, 1080p
  #     The config url only lists 270p, 360p, 1080p
  #   https://vimeo.com/70949607
  #     No download link on the page
  #     The config URL gives us 270p, 360p, 1080p
  #   https://vimeo.com/104323624
  #     No download link
  #     Simple info URL gives us only one size, 360p
  #     Signed info URL gives us 720p and 360p
  #   https://vimeo.com/117166426
  #     A private video
  #   https://vimeo.com/88309465
  #     "HTTP/1.1 451 Unavailable For Legal Reasons"
  #     "removed as a result of a third-party notification"
  #   https://vimeo.com/121870373
  #     A private video that isn't 404 for some reason
  #   https://vimeo.com/83711059
  #     The HTML page is 404, but the simple info URL works,
  #     and the video is downloadable anyway!
  #   https://vimeo.com/209
  #     Yes, this is a real video.  No "h264" in "files" metadata,
  #     only .flv as "vp6".
  #   https://www.vimeo.com/142574658
  #     Only has "progressive" formats, not h264.  Downloads fine though.

  ($http, $head, $body) = get_url ($info_url, $referer);

  my $err = undef;
  if (!check_http_status ($id, $info_url, $http, 0)) {
    ($err) = ($body =~ m@ \{ "message" : \s* " ( .+? ) " , @six);
    $err = "Private video" if ($err && $err =~ m/privacy setting/si);
    $err = $1 if ($body =~ m@([^<>.:]*verify that you are a human[^<>.:]*)@si);
    $err = $http . ($err ? ": $err" : "");
  } else {
    $http = '';  # 200
  }

  my ($title)  = ($body =~ m@    "title" : \s* " (.+?) ", @six);
  my ($files0) = ($body =~ m@ \{ "h264"  : \s* \{ ( .+? \} ) \} , @six);
  my ($files1) = ($body =~ m@ \{ "vp6"   : \s* \{ ( .+? \} ) \} , @six);
  my ($files2) = ($body =~ m@   "progressive" : \s* \[ ( .+? \] ) \} @six);
  my $files    = ($files0 || '') . ($files1 || '') . ($files2 || '');

  my ($thumb)  = ($body =~ m/"thumbs":\{"\d+":"(.*?)"/s);

  # Sometimes we get empty-ish data for "Private Video", but HTTP 200.
  $err = "No video info (Private video?)"
    if (!$err && !$title && !$files);

  if ($err) {
    if ($obody) {
      # The HTML page might provide an explanation for the error.
      my ($err2) = ($obody =~
                    m@ exception_data \s* = \s* { [^{}]*
                       "notification" \s* : \s* " (.*?) ",@six);
      if ($err2) {
        $err2 =~ s/\\n/\n/gs;    # JSON
        $err2 =~ s/\\//gs;
        $err2 =~ s/<[^<>]*>//gs; # Lose tags
        $err2 =~ s/^\s+//gs;
        $err2 =~ s/\n.*$//gs;    # Keep first para only.
        $err .= " $err2" if $err2;
      }
    }

    error ("$id: $err") if ($http || $err =~ m/Private/s);
    errorI ("$id: $err");
  }

  my %fmts;

  if ($files) {
    errorI ("$id: no title") unless $title;
    $fmts{title} = $title;
    my $i = 0;
    my %seen;
    foreach my $f (split (/\},?\s*/, $files)) {
      next unless (length($f) > 50);
    # my ($fmt)  = ($f =~ m@^ \" (.+?) \": @six);
    #    ($fmt)  = ($f =~ m@^ \{ "profile": (\d+) @six) unless $fmt;
      my ($fmt)  = ($f =~ m@^ \{ "profile": \"? (\d+) @six);
      next unless $fmt;
      next if ($seen{$fmt});
      my ($url2) = ($f =~ m@ "url"    : \s* " (.*?) " @six);
      my ($w)    = ($f =~ m@ "width"  : \s*   (\d+)   @six);
      my ($h)    = ($f =~ m@ "height" : \s*   (\d+)   @six);

      next unless $url2;
      errorI ("$id: unparsable vimeo video formats: $f")
        unless ($fmt && $url2 && $w && $h);
      print STDERR "$progname: $fmt: ${w}x$h: $url2\n"
        if ($verbose > 2);

      my ($ext) = ($url2 =~ m@ ^ [^?&]+ \. ( [^./?&]+ ) ( [?&] | $ ) @sx);
      $ext = 'mp4' unless $ext;
      my $ct = ($ext =~ m/^(flv|webm|3gpp?|av1)$/s ? "video/$ext" :
                $ext =~ m/^(mov)$/s                ? 'video/quicktime' :
                'video/mpeg');

      $seen{$fmt} = 1;
      my %v = ( fmt  => $i,
                url  => $url2,
                content_type => $ct,
                w    => $w,
                h    => $h,
                # size => undef,
                # abr  => undef,
              );
      $fmts{$i} = \%v;
      $i++;
    }
  }

  $fmts{thumb} = $thumb if ($thumb);

  return \%fmts;
}


# Returns a hash of:
#  [ title: "T",
#    year: "Y",
#    N: [ ...video info... ],
#    M: [ ...video info... ], ... ]
#
sub load_tumblr_formats($$$) {
  my ($id, $url, $size_p) = @_;

  # The old code doesn't work any more: I guess they locked down the 
  # video info URL to require an API key.  So we can just grab the
  # "400" version, I guess...
  {
    my ($http, $head, $body) = get_url ($url);
    check_http_status ($id, $url, $http, 1);

    # Incestuous
    if ($body =~ m@ <IFRAME [^<>]*? \b SRC="
                     ( https?:// [^<>\"/]*? \b 
                       ( vimeo\.com | youtube\.com | 
                         instagram\.com )
                       [^<>\"]+ )
                  @six) {
      return load_formats ($1, $size_p);
    }

    my ($title) = ($body =~ m@<title>\s*(.*?)</title>@six);

    if (! ($body =~ m@<meta \s+ property="og:type" \s+
                          content="[^\"<>]*?video@six)) {
      exit (1) if ($verbose <= 0); # Skip silently if --quiet.
      error ("not a Tumblr video URL: $url $verbose");
    }

    my ($img)   = ($body =~ m@<meta \s+ property="og:image" \s+
            content="([^<>]*?)"@six);
    error ("no title: $url\n$body") unless $title;
    error ("no og:image: $url") unless $img;
    $img =~ s@_[^/._]+\.[a-z]+$@_480.mp4@si;
    error ("couldn't find video URL: $url")
      unless ($img =~ m/\.mp4$/s);

    $img =~ s@^https?://[^/]+@https://vt.tumblr.com@si;

    $title = munge_title (html_unquote ($title || ''));
    sanity_check_title ($title, $url, $body, 'load_tumblr_formats');
    my $fmts = {};
    my $i = 0;
    my ($w, $h) = (0, 0);
    my %v = ( fmt  => $i,
              url  => $img,
              content_type => 'video/mp4',
              w    => $w,
              h    => $h,
              # size => undef,
              # abr  => undef,
            );
    $fmts->{$i} = \%v;

    $fmts->{title} = $title;
    # $fmts->{year}  = $year;

    return $fmts;
  }

  # The following no longer works.


  my ($host) = ($url =~ m@^https?://([^/]+)@si);
  my $info_url = "https://api.tumblr.com/v2/blog/$host/posts/video?id=$id";

  my ($http, $head, $body) = get_url ($info_url);
  check_http_status ($id, $url, $http, 1);

  $body =~ s/^.* "posts" : \[ //six;

  my ($title) = ($body =~ m@ "slug" : \s* \" (.+?) \" @six);
  my ($year)  = ($body =~ m@ "date" : \s* \" (\d{4})- @six);

  $title = munge_title (html_unquote ($title || ''));
  sanity_check_title ($title, $url, $body, 'load_tumblr_formats 2');

  my $fmts = {};

  $body =~ s/^.* "player" : \[ //six;

  my $i = 0;
  foreach my $chunk (split (/\},/, $body)) {
    my ($e) = ($chunk =~ m@ "embed_code" : \s* " (.*?) " @six);

    $e =~ s/\\n/\n/gs;
    $e =~ s/ \\[ux] \{ ([a-z0-9]+)   \} / unihex($1) /gsexi;  # \u{XXXXXX}
    $e =~ s/ \\[ux]   ([a-z0-9]{4})   / unihex($1) /gsexi;  # \uXXXX
    $e =~ s/\\//gs;

    my ($w)   = ($e =~ m@width=['"]?(\d+)@si);
    my ($h)   = ($e =~ m@height=['"]?(\d+)@si);
    my ($src) = ($e =~ m@<source\b(.*?)>@si);
    my ($v)   = ($src =~ m@src=['"](.*?)['"]@si);
    my ($ct)  = ($src =~ m@type=['"](.*?)['"]@si);

    my %v = ( fmt  => $i,
              url  => $v,
              content_type => $ct,
              w    => $w,
              h    => $h,
              # size => undef,
              # abr  => undef,
            );
    $fmts->{$i} = \%v;
    $i++;
  }

  $fmts->{title} = $title;
  $fmts->{year}  = $year;

  return $fmts;
}


# Returns a hash of:
#  [ title: "T",
#    year: "Y",
#    0: [ ...video info... ],
# Since Instagram only offers one resolution.
#
sub load_instagram_formats($$$) {
  my ($id, $url, $size_p) = @_;

  my ($http, $head, $body) = get_url ($url);
  check_http_status ($id, $url, $http, 1);

  my ($title) = ($body =~ m@<meta \s+ property="og:title" \s+
         content="([^<>]*?)"@six);
  my ($src)   = ($body =~ m@<meta \s+ property="og:video:secure_url" \s+
         content="([^<>]*?)"@six);
  my ($w)     = ($body =~ m@<meta \s+ property="og:video:width" \s+
         content="([^<>]*?)"@six);
  my ($h)     = ($body =~ m@<meta \s+ property="og:video:height" \s+
         content="([^<>]*?)"@six);
  my ($ct)    = ($body =~ m@<meta \s+ property="og:video:type" \s+
         content="([^<>]*n?)"@six);
  my ($year)  = ($body =~ m@\bdatetime="(\d{4})-@six);
  my ($thumb) = ($body =~ m@<meta \\s+ property="og:image"     \s+
         content="([^<>]*n?)"@six);

  error ("$id: no video in $url")
    unless ($src && $w && $h && $ct && $title);

  $title = munge_title (html_unquote ($title || ''));
  sanity_check_title ($title, $url, $body, 'load_instagram_formats');
  $ct =~ s/;.*//s;

  my $fmts = {};

  my $i = 0;
  my %v = ( fmt  => $i,
            url  => $src,
            content_type => $ct,
            w    => $w,
            h    => $h,
            # size => undef,
            # abr  => undef,
          );
  $fmts->{$i} = \%v;

  $fmts->{title} = $title;
  $fmts->{year}  = $year;
  $fmts->{thumb} = $thumb if $thumb;

  return $fmts;
}

# Returns a hash of:
#  [ title: "T",
#    year: "Y",
#    0: [ ...video info... ],
# Since Twitter only offers one resolution.
#
sub load_twitter_formats($$$) {
  my ($id, $url, $size_p) = @_;

  my ($http, $head, $body) = get_url ($url);
  check_http_status ($id, $url, $http, 1);
  my ($title) = ($body =~ m@<meta \s+ property="og:title" \s+
         content="([^<>]*?)"@six);

  $url = "https://twitter.com/i/videos/tweet/$id";
  ($http, $head, $body) = get_url ($url);
  check_http_status ($id, $url, $http, 1);

  my ($id2) = ($body =~ m@/tweet_video\\?/([^<>&?.]+)@s);
# ($id2) = ($body =~ m@/web-video-player/([^<>&?/\\]+)@s) unless $id2;
# ($id2) = ($body =~ m@/ext_tw_video\\?/([^<>&?/\\]+)@s) unless $id2;

#  errorI ("$id: video ID not found\n$body") unless ($id2);
  my $src;
  if ($id2) {
    $src = "https://pbs.twimg.com/tweet_video/$id2.mp4";
  } else {
    my $url2 = "https://twitter.com/i/videos/$id";
    ($http, $head, $body) = get_url ($url2);
    check_http_status ($id, $url2, $http, 1);
    ($id2) = ($body =~ m@/ext_tw_video\\?/([^<>&?/\\]+)@s);
    $body = html_unquote($body);
    ($src) = ($body =~ m@"video_url":"([^\"]+)"@si);
    error ("Twitter is a piece of shit, none of this works any more")
      unless ($src);
    errorI ("$id: video_url not found") unless ($src);
    $src =~ s/\\//gs;

    # Now Twitter is giving us an ".m3u8u" chunked file instead of an .mp4
    # because fuck you that's why.
    #
    if ($src =~ m@\.m3u[^/]+$@s) {
      # ($http, $head, $body) = get_url ($src);
      #### ...
      error ("Twitter is a piece of shit, we can't handle .m3u8u video");
    }
  }

  $title =~ s/ on Twitter$//s;
  $title = munge_title (html_unquote ($title || ''));
  sanity_check_title ($title, $url, $body, 'load_twitter_formats');

  my $ct = 'image/mp4';
  my ($w, $h) = (0, 0);
  my $year = undef;

  my $fmts = {};

  my $i = 0;
  my %v = ( fmt  => $i,
            url  => $src,
            content_type => $ct,
            w    => $w,
            h    => $h,
            # size => undef,
            # abr  => undef,
          );
  $fmts->{$i} = \%v;

  $fmts->{title} = $title;
  $fmts->{year}  = $year;

  return $fmts;
}


# Return the year at which this video was uploaded.
#
my %youtube_year_cache;
sub get_youtube_year($;$) {
  my ($id, $body) = @_;

  # Avoid loading the page twice.
  my $year = $youtube_year_cache{$id};
  return $year if $year;

  # 13-May-2015: https://www.youtube.com/watch?v=99lDR6jZ8yE (Lamb)
  # HTML says this:
  #     <strong class="watch-time-text">Uploaded on Oct 28, 2011</strong>
  # But /feeds/api/videos/99lDR6jZ8yE?v=2 says:
  #     <updated>     2015-05-13T21:13:28.000Z
  #     <published>   2015-04-17T15:23:22.000Z
  #     <yt:uploaded> 2015-04-17T15:23:22.000Z
  #
  # And one of my own: https://www.youtube.com/watch?v=HbN4wBJMOuE
  #     <strong class="watch-time-text">Published on Sep 20, 2014</strong>
  #     <published>   2015-04-17T15:23:22.000Z
  #     <updated>     2015-05-16T18:48:26.000Z
  #     <yt:uploaded> 2015-04-17T15:23:22.000Z
  #
  # In fact, I uploaded that on Sep 20, 2014, and when I did I set the
  # Advanced Settings / Recording Date to Sep 14, 2014.  Some time in
  # 2015, I edited the description text.  I have no theory for why the
  # "published" and "updated" dates are different and are both 2015.
  #
  # So, let's scrape the HTML instead of using the API.
  #
  # (Actually, we don't have a choice now anyway, since they turned off
  # the v2 API in June 2015, and the v3 API requires authentication.)

  # my $data_url = ("https://gdata.youtube.com/feeds/api/videos/$id?v=2" .
  #                 "&fields=published" .
  #                 "&safeSearch=none" .
  #                 "&strict=true");
  my $data_url = "https://www.youtube.com/watch?v=$id";

  my ($http, $head);
  if (! $body) {
    ($http, $head, $body) = get_url ($data_url);
    return undef unless check_http_status ($id, $data_url, $http, 0);
  }

  # my ($year, $mon, $dotm, $hh, $mm, $ss) =
  #   ($body =~ m@<published>(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)@si);

  ($year) = ($body =~ m@\bclass="watch-time-text">[^<>]+\b(\d{4})</@s);

  # Jul 2020
  ($year) = ($body =~ m@\"uploadDate\\?\":\\?\"(\d{4})-\d\d-@si)
    unless $year;
  ($year) = ($body =~ m@\"uploadDate\" content=\"(\d{4})-\d\d-@si)
    unless $year;

  $youtube_year_cache{$id} = $year;
  return $year;
}


# Return the year at which this video was uploaded.
#
sub get_vimeo_year($) {
  my ($id) = @_;
  my $data_url = "https://vimeo.com/api/v2/video/$id.xml";
  my ($http, $head, $body) = get_url ($data_url);
  return undef unless check_http_status ($id, $data_url, $http, 0);

  my ($year, $mon, $dotm, $hh, $mm, $ss) =
    ($body =~ m@<upload_date>(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)@si);
  return $year;
}


my $ffmpeg_warned_p = 0;

# Given a list of available underlying videos, pick the ones we want.
#
sub pick_download_format($$$$$$) {
  my ($id, $site, $url, $force_fmt, $fmts, $max_size) = @_;

  my ($maxw, $maxh) = ($max_size =~ m/^(\d+)x(\d+)$/s)
    if defined($max_size);

  if (defined($force_fmt) && $force_fmt eq 'all') {
    my @all = ();
    foreach my $k (keys %$fmts) {
      next if ($k eq 'title' || $k eq 'year' || $k eq 'cipher' ||
               $k eq 'thumb');
      next if (($maxw && ($fmts->{$k}->{w} || 0) > $maxw) ||
               ($maxh && ($fmts->{$k}->{h} || 0) > $maxh));
      push @all, $k;
    }
    return sort { $a <=> $b } @all;
  }

  if ($site eq 'vimeo' ||
      $site eq 'tumblr' ||
      $site eq 'instagram' ||
      $site eq 'twitter') {
    # On these sites, just pick the entry with the largest size
    # and/or resolution.

    # No muxing needed on Vimeo
    $force_fmt = undef if ($force_fmt && $force_fmt eq 'mux');

    if (defined($force_fmt)) {
      error ("$site --fmt must be digits: $force_fmt")
        unless ($force_fmt =~ m/^\d+$/s);
      foreach my $k (keys %$fmts) {
        if ($k eq $force_fmt) {
          print STDERR "$progname: $id: forced #$k (" .
                       $fmts->{$k}->{w} . " x " .
                       $fmts->{$k}->{h} . ")\n"
            if ($verbose > 1);
          return $k;
        }
      }
      error ("$id: format $force_fmt does not exist");
    }

    my $best = undef;
    foreach my $k (keys %$fmts) {
      next if ($k eq 'title' || $k eq 'year' || $k eq 'cipher' ||
               $k eq 'thumb');
      $best = $k
        if (!defined($best) ||
            (($fmts->{$k}->{size} || 0) > ($fmts->{$best}->{size} || 0) ||
             ($fmts->{$k}->{w}    * $fmts->{$k}->{h} >
              $fmts->{$best}->{w} * $fmts->{$best}->{h})));
    }
    print STDERR "$progname: $id: picked #$best (" .
                 $fmts->{$best}->{w} . " x " .
                 $fmts->{$best}->{h} . ")\n"
      if ($verbose > 1);
    return $best;
  } elsif ($site ne 'youtube') {
    errorI ("unknown site $site");
  }

  errorI ("$id: unrecognized site: $url") unless ($site eq 'youtube');

  my %known_formats = (
   #
   # v=undef means it's an audio-only format.
   # a=undef means it's a video-only format.
   # Codecs "mp4S" and "webmS" are 3d video (left/right stereo).
   #
   # ID   video container    video size        audio codec    bitrate
   #
   0   => { v => 'flv',  w =>  320, h =>  180, a => 'mp3', abr =>  64   },
   5   => { v => 'flv',  w =>  320, h =>  180, a => 'mp3', abr =>  64   },
   6   => { v => 'flv',  w =>  480, h =>  270, a => 'mp3', abr =>  96   },
   13  => { v => '3gp',  w =>  176, h =>  144, a => 'amr', abr =>  13   },
   17  => { v => '3gp',  w =>  176, h =>  144, a => 'aac', abr =>  24   },
   18  => { v => 'mp4',  w =>  480, h =>  360, a => 'aac', abr => 125   },
   22  => { v => 'mp4',  w => 1280, h =>  720, a => 'aac', abr => 198   },
   34  => { v => 'flv',  w =>  640, h =>  360, a => 'aac', abr =>  52   },
   35  => { v => 'flv',  w =>  854, h =>  480, a => 'aac', abr => 107   },
   36  => { v => '3gp',  w =>  320, h =>  240, a => 'aac', abr =>  37   },
   37  => { v => 'mp4',  w => 1920, h => 1080, a => 'aac', abr => 128   },
   38  => { v => 'mp4',  w => 4096, h => 2304, a => 'aac', abr => 128   },
   43  => { v => 'webm', w =>  640, h =>  360, a => 'vor', abr => 128   },
   44  => { v => 'webm', w =>  854, h =>  480, a => 'vor', abr => 128   },
   45  => { v => 'webm', w => 1280, h =>  720, a => 'vor', abr => 128   },
   46  => { v => 'webmS',w => 1920, h => 1080, a => 'vor', abr => 128   },
   59  => { v => 'mp4',  w =>  854, h =>  480, a => 'aac', abr => 128   },
   78  => { v => 'mp4',  w =>  720, h =>  406, a => 'aac', abr => 128   },
   82  => { v => 'mp4S', w =>  640, h =>  360, a => 'aac', abr => 128   },
   83  => { v => 'mp4S', w =>  854, h =>  240, a => 'aac', abr => 128   },
   84  => { v => 'mp4S', w => 1280, h =>  720, a => 'aac', abr => 198   },
   85  => { v => 'mp4S', w => 1920, h =>  520, a => 'aac', abr => 198   },
   92  => { v => 'mp4',  w =>  320, h =>  240, a => undef               },
   93  => { v => 'mp4',  w =>  640, h =>  360, a => undef               },
   94  => { v => 'mp4',  w =>  854, h =>  480, a => undef               },
   95  => { v => 'mp4',  w => 1280, h =>  720, a => undef               },
   96  => { v => 'mp4',  w => 1920, h => 1080, a => undef               },
   100 => { v => 'webmS',w =>  640, h =>  360, a => 'vor', abr => 128   },
   101 => { v => 'webmS',w =>  854, h =>  480, a => 'vor', abr => 128   },
   102 => { v => 'webmS',w => 1280, h =>  720, a => 'vor', abr => 128   },
   120 => { v => 'flv',  w => 1280, h =>  720, a => 'aac', abr => 128   },
   132 => { v => 'mp4',  w =>  320, h =>  240, a => undef               },
   133 => { v => 'mp4',  w =>  426, h =>  240, a => undef               },
   134 => { v => 'mp4',  w =>  640, h =>  360, a => undef               },
   135 => { v => 'mp4',  w =>  854, h =>  480, a => undef               },
   136 => { v => 'mp4',  w => 1280, h =>  720, a => undef               },
   137 => { v => 'mp4',  w => 1920, h => 1080, a => undef               },
   138 => { v => 'mp4',  w => 3840, h => 2160, a => undef               },
   139 => { v => undef,                        a => 'm4a', abr =>  48   },
   140 => { v => undef,                        a => 'm4a', abr => 128   },
   141 => { v => undef,                        a => 'm4a', abr => 256   },
   142 => { v => 'mp4',  w =>  426, h =>  240, a => undef               },
   143 => { v => 'mp4',  w =>  640, h =>  360, a => undef               },
   144 => { v => 'mp4',  w =>  854, h =>  480, a => undef               },
   145 => { v => 'mp4',  w => 1280, h =>  720, a => undef               },
   146 => { v => 'mp4',  w => 1920, h => 1080, a => undef               },
   148 => { v => undef,                        a => 'aac', abr => 51    },
   149 => { v => undef,                        a => 'aac', abr => 132   },
   150 => { v => undef,                        a => 'aac', abr => 260   },
   151 => { v => 'mp4',  w =>   72, h =>   32, a => undef               },
   160 => { v => 'mp4',  w =>  256, h =>  144, a => undef               },
   161 => { v => 'mp4',  w =>  256, h =>  144, a => undef               },
   167 => { v => 'webm', w =>  640, h =>  360, a => undef               },
   168 => { v => 'webm', w =>  854, h =>  480, a => undef               },
   169 => { v => 'webm', w => 1280, h =>  720, a => undef               },
   170 => { v => 'webm', w => 1920, h => 1080, a => undef               },
   171 => { v => undef,                        a => 'vor', abr => 128   },
   172 => { v => undef,                        a => 'vor', abr => 256   },
   218 => { v => 'webm', w =>  854, h =>  480, a => undef               },
   219 => { v => 'webm', w =>  854, h =>  480, a => undef               },
   222 => { v => 'mp4',  w =>  854, h =>  480, a => undef               },
   223 => { v => 'mp4',  w =>  854, h =>  480, a => undef               },
   224 => { v => 'mp4',  w => 1280, h =>  720, a => undef               },
   225 => { v => 'mp4',  w => 1280, h =>  720, a => undef               },
   226 => { v => 'mp4',  w => 1920, h => 1080, a => undef               },
   227 => { v => 'mp4',  w => 1920, h => 1080, a => undef               },
   242 => { v => 'webm', w =>  426, h =>  240, a => undef               },
   243 => { v => 'webm', w =>  640, h =>  360, a => undef               },
   244 => { v => 'webm', w =>  854, h =>  480, a => undef               },
   245 => { v => 'webm', w =>  854, h =>  480, a => undef               },
   246 => { v => 'webm', w =>  854, h =>  480, a => undef               },
   247 => { v => 'webm', w => 1280, h =>  720, a => undef               },
   248 => { v => 'webm', w => 1920, h => 1080, a => undef               },
   249 => { v => undef,                        a => 'vor', abr =>  50   },
   250 => { v => undef,                        a => 'vor', abr =>  70   },
   251 => { v => undef,                        a => 'vor', abr => 160   },
   256 => { v => undef,                        a => 'm4a', abr =>  97, c=>5.1},
   258 => { v => undef,                        a => 'm4a', abr => 191, c=>5.1},
   264 => { v => 'mp4',  w => 2560, h => 1440, a => undef               },
   266 => { v => 'mp4',  w => 3840, h => 2160, a => undef               },
   271 => { v => 'webm', w => 2560, h => 1440, a => undef               },
   272 => { v => 'webm', w => 3840, h => 2160, a => undef               },
   273 => { v => 'webm', w =>  854, h =>  480, a => undef               },
   274 => { v => 'webm', w => 1280, h =>  720, a => undef               },
   275 => { v => 'webm', w => 1920, h => 1080, a => undef               },
   278 => { v => 'webm', w =>  256, h =>  144, a => undef               },
   279 => { v => 'webm', w =>  426, h =>  240, a => undef               },
   280 => { v => 'webm', w =>  640, h =>  360, a => undef               },
   298 => { v => 'mp4',  w => 1280, h =>  720, a => undef               },
   299 => { v => 'mp4',  w => 1920, h => 1080, a => undef               },
   302 => { v => 'webm', w => 1280, h =>  720, a => undef               },
   303 => { v => 'webm', w => 1920, h => 1080, a => undef               },
   304 => { v => 'mp4',  w => 2560, h => 1440, a => undef               },
   305 => { v => 'mp4',  w => 3840, h => 1920, a => undef               },
#  308 => { v => 'mp4',  w => 2560, h => 1440, a => undef               },
   308 => { v => 'webm', w => 2560, h => 1440, a => undef               },
   313 => { v => 'webm', w => 3840, h => 2160, a => undef               },
   315 => { v => 'webm', w => 3840, h => 2160, a => undef               },
   317 => { v => 'webm', w =>  854, h =>  480, a => undef               },
   318 => { v => 'webm', w =>  854, h =>  480, a => undef               },
   327 => { v => undef,                        a => 'm4a', abr => 128, c=>5.1 },
   328 => { v => undef,                        a => 'ec3', abr => 384, c=>5.1 },
   330 => { v => 'webm', w => 256,  h =>  144, a => undef               },
   331 => { v => 'webm', w => 426,  h =>  240, a => undef               },
   332 => { v => 'webm', w => 640,  h =>  360, a => undef               },
   333 => { v => 'webm', w => 854,  h =>  480, a => undef               },
   334 => { v => 'webm', w => 1280, h =>  720, a => undef               },
   335 => { v => 'webm', w => 1920, h => 1080, a => undef               },
   336 => { v => 'webm', w => 2560, h => 1440, a => undef               },
   337 => { v => 'webm', w => 3840, h => 2160, a => undef               },
   338 => { v => undef,                        a => 'vor', abr =>   4   },
   339 => { v => undef,                        a => 'vor', abr => 170, c=>5.1 },
   350 => { v => undef,                        a => 'vor', abr =>  50   },
   351 => { v => undef,                        a => 'vor', abr =>  49   },
   352 => { v => undef,                        a => 'vor', abr =>   3   },
   357 => { v => 'webm', w => 1280, h =>  720, a => undef               },
   358 => { v => 'webm', w => 1280, h =>  720, a => undef               },
   359 => { v => 'webm', w => 1920, h => 1080, a => undef               },
   360 => { v => 'webm', w => 1920, h => 1080, a => undef               },
   380 => { v => undef,                        a => 'ac3', abr => 384, c=>5.1 },
   394 => { v => 'av1',  w =>  256, h =>  144, a => undef               },
   395 => { v => 'av1',  w =>  426, h =>  240, a => undef               },
   396 => { v => 'av1',  w =>  640, h =>  360, a => undef               },
   397 => { v => 'av1',  w =>  854, h =>  480, a => undef               },
   398 => { v => 'av1',  w => 1280, h =>  720, a => undef               },
   399 => { v => 'av1',  w => 1920, h => 1080, a => undef               },
   400 => { v => 'av1',  w => 2560, h => 1440, a => undef               },
   401 => { v => 'av1',  w => 3840, h => 2160, a => undef               },
   402 => { v => 'av1',  w => 3840, h => 2160, a => undef               },
   403 => { v => 'av1',  w => 5888, h => 2160, a => undef               },
   571 => { v => 'av1',  w => 7680, h => 4320, a => undef               },
   597 => { v => 'mp4',  w =>  256, h =>  144, a => undef               },
   598 => { v => 'webm', w =>  256, h =>  144, a => undef               },
   599 => { v => undef,                        a => 'aac',  abr =>  30  },
   600 => { v => undef,                        a => 'opus', abr =>  35  },
   694 => { v => 'av1',  w =>  256, h =>  144, a => undef               },
   695 => { v => 'av1',  w =>  426, h =>  240, a => undef               },
   696 => { v => 'av1',  w =>  640, h =>  360, a => undef               },
   697 => { v => 'av1',  w =>  854, h =>  480, a => undef               },
   698 => { v => 'av1',  w => 1280, h =>  720, a => undef               },
   699 => { v => 'av1',  w => 1920, h => 1080, a => undef               },
   'rawcc' => { },
  );
  #
  # The table on https://en.wikipedia.org/wiki/YouTube#Quality_and_formats
  # disagrees with the above to some extent.  Which is more accurate?
  # (Oh great, they deleted that table from Wikipedia. Lovely.)
  # (Ah great, they added the table back to Wikipedia Mar 2016.)
  # (Aaaand it's gone again, some time before Mar 2019.)
  #
  # fmt=38/37/22 are only available if upload was that exact resolution.
  #
  # For things uploaded in 2009 and earlier, fmt=18 was higher resolution
  # than fmt=34.  But for things uploaded later, fmt=34 is higher resolution.
  # This code assumes that 34 is the better of the two.
  #
  # The WebM formats 43, 44 and 45 began showing up around Jul 2011.
  # The MP4 versions are higher resolution (e.g. 37=1080p but 45=720p).
  #
  # The stereo/3D formats 46, 82-84, 100-102 first spotted in Sep/Nov 2011.
  #
  # As of Jan 2015, Youtube seems to have stopped serving format 37 (1080p),
  # but is instead serving 137 (1080p, video only). To download anything of
  # 1080p or higher, you are expected to download a video-only and an
  # audio-only stream and mux them on the client side.  This is insane.
  # It seems that "urlmap" contains the muxed videos and "adaptive_fmts"
  # contains the unmuxed ones.
  #
  # For debugging this stuff, use "--fmt N" to force downloading of a
  # particular format or "--fmt all" to grab them all.
  #
  #
  # Test cases and examples:
  #
  #   https://www.youtube.com/watch?v=wjzyv2Q_hdM
  #   5-Aug-2011: 38=flv/1080p but 45=webm/720p.
  #   6-Aug-2011: 38 no longer offered.
  #
  #   https://www.youtube.com/watch?v=ms1C5WeSocY
  #   6-Aug-2011: embedding disabled, but get_video_info works.
  #
  #   https://www.youtube.com/watch?v=g40K0dFi9Bo
  #   10-Sep-2011: 3D, fmts 82 and 84.
  #
  #   https://www.youtube.com/watch?v=KZaVq1tFC9I
  #   14-Nov-2011: 3D, fmts 100 and 102.  This one has 2D images in most
  #   formats but left/right images in the 3D formats.
  #
  #   https://www.youtube.com/watch?v=SlbpRviBVXA
  #   15-Nov-2011: 3D, fmts 46, 83, 85, 101.  This one has left/right images
  #   in all of the formats, even the 2D formats.
  #
  #   https://www.youtube.com/watch?v=711bZ_pLusQ
  #   30-May-2012: First sighting of fmt 36, 3gpp/240p.
  #
  #   https://www.youtube.com/watch?v=0yyorhl6IjM
  #   30-May-2013: Here's one that's more than an hour long.
  #
  #   https://www.youtube.com/watch?v=pc4ANivCCgs
  #   15-Nov-2013: First sighting of formats 59 and 78.
  #
  #   https://www.youtube.com/watch?v=WQzVhOZnku8
  #   3-Sep-2014: First sighting of a 24/7 realtime stream.
  #
  #   https://www.youtube.com/watch?v=gTIK2XawLDA
  #   22-Jan-2015: DNA Lounge 24/7 live stream, 640x360.
  #
  #   https://www.youtube.com/watch?v=hHKJ5eE7I1k
  #   22-Jan-2015: 2K video. Formats 36, 136, 137, 138.
  #
  #   https://www.youtube.com/watch?v=udAL48P5NJU
  #   22-Jan-2015: 4K video. Formats 36, 136, 137, 138, 266, 313.
  #
  #   https://www.youtube.com/watch?v=OEhRucEVzH8
  #   20-Feb-2015: best formats 18 (640 x 360) and 135 (854 x 480)
  #   First sighting of a video where we must mux to get the best
  #   non-HD version.
  #
  #   https://www.youtube.com/watch?v=Ol61WOSzLF8
  #   10-Mar-2015: formerly RTMPE but 14-Apr-2015 no longer
  #
  #   https://www.youtube.com/watch?v=1ltcDfZMA3U  Maps
  #   29-Mar-2015: formerly playable in US region, but no longer
  #
  #   https://www.youtube.com/watch?v=ttqMGYHhFFA  Metric
  #   29-Mar-2015: Formerly enciphered, but no longer
  #
  #   https://www.youtube.com/watch?v=7wL9NUZRZ4I  Bowie
  #   29-Mar-2015: Formerly enciphered and content warning; no longer CW.
  #
  #   https://www.youtube.com/watch?v=07FYdnEawAQ Timberlake
  #   29-Mar-2015: enciphered and "content warning" (HTML scraping fails)
  #
  #   https://youtube.com/watch?v=HtVdAasjOgU
  #   29-Mar-2015: content warning, but non-enciphered
  #
  #   https://www.youtube.com/watch?v=__2ABJjxzNo
  #   29-Mar-2015: has url_encoded_fmt_stream_map but not adaptive_fmts
  #
  #   https://www.youtube.com/watch?v=lqQg6PlCWgI
  #   29-Mar-2015: finite-length archive of a formerly livestreamed video.
  #   We currently can't download this, but it's doable.
  #   See dna/backstage/src/slideshow/slideshow-youtube-frame.pl
  #   Update, 7-Aug-2016: this one works now; it seems to have been
  #   converted to a normal video with a url map.
  #
  #   Enciphered:
  #   https://www.youtube.com/watch?v=ktoaj1IpTbw  Chvrches
  #   https://www.youtube.com/watch?v=28Vu8c9fDG4  Emika
  #   https://www.youtube.com/watch?v=_mDxcDjg9P4  Vampire Weekend
  #   https://www.youtube.com/watch?v=8UVNT4wvIGY  Gotye
  #   https://www.youtube.com/watch?v=OhhOU5FUPBE  Black Sabbath
  #   https://www.youtube.com/watch?v=UxxajLWwzqY  Icona Pop
  #
  #   https://www.youtube.com/watch?v=g_uoH6hJilc
  #   28-Mar-2015: enciphered Vevo (Years & Years) on which CTF was failing
  #
  #   https://www.youtube.com/watch?v=ccyE1Kz8AgM
  #   28-Mar-2015: not viewable in US (US is not on the include list)
  #
  #   https://www.youtube.com/watch?v=ccyE1Kz8AgM
  #   28-Mar-2015: blocked in US (US is on the exclude list)
  #
  #   https://www.youtube.com/watch?v=GjxOqc5hhqA
  #   28-Mar-2015: says "please sign in", but when signed in, it's private
  #
  #   https://www.youtube.com/watch?v=UlS_Rnb5WM4
  #   28-Mar-2015: non-embeddable (Pogo)
  #
  #   https://www.youtube.com/watch?v=JYEfJhkPK7o
  #   14-Apr-2015: RTMPE DRM
  #   get_video_info fails with "This video contains content from Mosfilm,
  #   who has blocked it from display on this website.  Watch on Youtube."
  #   There's a generic rtmpe: URL in "conn" and a bunch of options in
  #   "stream", but I don't know how to put those together into an
  #   invocation of "rtmpdump" that does anything at all.
  #
  #   https://www.youtube.com/watch?v=UXMG102kSvk
  #   17-Aug-2015: WebM higher rez than MP4:
  #   299 (1920 x 1080 mp4 v/o)
  #   308 (2560 x 1440 webm v/o)  <-- webm, not mp4
  #   315 (3840 x 2160 webm v/o)
  #
  #   https://www.youtube.com/watch?v=dC_nFgJAcuQ
  #   2-Dec-2015: First sighting of 5.1 stereo formats 256 and 258.
  #
  #   https://www.youtube.com/watch?v=vBtlUl-Xh5w
  #   30-Jun-2016: First sighting of 5.1 stereo formats 327 and 339.
  #
  #   https://www.youtube.com/watch?v=uTnO1ITQWr0
  #   6-Aug-2016: finite-length archive of a formerly livestreamed video.
  #   This is Flash-player only because it has embedding disabled.
  #   We currently can't download this, but it's doable.
  #   See dna/backstage/src/slideshow/slideshow-youtube-frame.pl
  #
  #   https://www.youtube.com/watch?v=oVjMF_TfY6M
  #   17-Aug-2018: Content warning and not embeddable
  #
  #   https://www.youtube.com/watch?v=HtfKRdRJIEs
  #   17-Dec-2018: fmt 135 from dashmpd works, but fmt 135 HTML is 404.
  #
  #   https://www.youtube.com/watch?v=I_MkW0CW4QM
  #   17-Dec-2018: both dashmpd and non, fmt 137
  #
  #   https://www.youtube.com/watch?v=6od76UNHt-M
  #   13-Jan-2019, only one format, 18
  #
  #   https://www.youtube.com/watch?v=jy0Q75xCwDU
  #   26-May-2019, no pre-muxed formats, can't be downloaded without ffmpeg.
  #
  #   https://www.youtube.com/watch?v=m1jY2VLCRmY
  #   19-Dec-2020: MP4 is 1080p, WebM is 3840x2160, AV1 is 7680x4320
  #
  #   https://www.youtube.com/watch?v=-s0kuc-C4AI
  #   https://www.youtube.com/watch?v=qp9_L3E8yiM
  #   19-Dec-2020: HTML has ytInitialPlayerResponse but no adaptive_fmts, etc.
  #
  #   https://www.youtube.com/watch?v=pbRVqWbHGuo
  #   21-Jul-2022: saw first non-integer format 'rawcc'

  # Divide %known_formats into muxed, video-only and audio-only lists.
  #
  my (@pref_muxed, @pref_vo, @pref_ao);
  foreach my $id (keys (%known_formats)) {
    my $fmt = $known_formats{$id};
    my $v = $fmt->{v};
    my $a = $fmt->{a};
    my $b = $fmt->{abr};
    my $c = $fmt->{c};   # channels (e.g. 5.1)
    my $w = $fmt->{w};
    my $h = $fmt->{h};

    $known_formats{$id}->{desc} = (($w && $h ? "$w x $h $v" :
                                    $b ? "$b kbps $a" :
                                    "?x?") .
                                   ($c ? " $c" : '') .
                                   ($w && $h && $b ? '' :
                                    $w ? ' v/o' : ' a/o'));

    error ("W and H flipped: $id") if ($w && $h && $w < $h);

    # Ignore 3d video or other weirdo vcodecs.
    next if ($v && !($v =~ m/^(mp4|flv|3gpp?|webm|av1)$/));

    if (! $webm_p) {
      # Skip WebM and Vorbis if desired.
      next if ($a && !$v && $a =~ m/^(vor)$/);
      next if (!$a && $v && $v =~ m/^(webm|av1)$/);
    }

    if ($v && $a) {
      push @pref_muxed, $id;
    } elsif ($v) {
      push @pref_vo, $id;
    } else {
      push @pref_ao, $id;
    }
  }

  # Sort each of those lists in order of download preference.
  #
  foreach my $S (\@pref_muxed, \@pref_vo, \@pref_ao) {
    @$S = sort {
      my $A = $known_formats{$a};
      my $B = $known_formats{$b};

      # If there is a max-size, prefer the fmt that is at or below it.
      if (defined($maxw) && $A->{w} && $B->{w}) {
        return  1 if ($A->{w} > $maxw && $B->{w} <= $maxw);
        return -1 if ($B->{w} > $maxw && $A->{w} <= $maxw);
        return  1 if ($A->{h} > $maxh && $B->{h} <= $maxh);
        return -1 if ($B->{h} > $maxh && $A->{h} <= $maxh);
      }

      my $aa = $A->{h} || 0;
      my $bb = $B->{h} || 0;
      return ($bb - $aa) unless ($aa == $bb); # Prefer taller video.

      $aa = (($A->{v} || '') eq 'mp4');   # Prefer MP4 over WebM / AV1.
      $bb = (($B->{v} || '') eq 'mp4');
      return ($bb - $aa) unless ($aa == $bb);

      $aa = $A->{c} || 0;     # Prefer 5.1 over stereo.
      $bb = $B->{c} || 0;
      return ($bb - $aa) unless ($aa == $bb);

      $aa = $A->{abr} || 0;     # Prefer higher audio rate.
      $bb = $B->{abr} || 0;
      return ($bb - $aa) unless ($aa == $bb);

      $aa = (($A->{a} || '') eq 'aac');   # Prefer AAC over MP3.
      $bb = (($B->{a} || '') eq 'aac');
      return ($bb - $aa) unless ($aa == $bb);

      $aa = (($A->{a} || '') eq 'mp3');   # Prefer MP3 over Vorbis.
      $bb = (($B->{a} || '') eq 'mp3');
      return ($bb - $aa) unless ($aa == $bb);

      return 0;
    } @$S;
  }

  my $vfmt = undef;
  my $afmt = undef;
  my $mfmt = undef;

  # Find the best pre-muxed format.
  #
  foreach my $target (@pref_muxed) {
    if ($fmts->{$target}) {
      $mfmt = $target;
      last;
    }
  }

  # If muxing is allowed, find the best un-muxed pair of formats, if
  # such a pair exists that is higher resolution than the best
  # pre-muxed format.
  #
  if (defined($force_fmt) && $force_fmt eq 'mux') {
    foreach my $target (@pref_vo) {
      if ($fmts->{$target}) {
        $vfmt = $target;
        last;
      }
    }

    # WebM must always be paired with Vorbis audio.
    # MP4 must always be paired with MP3, M4A or AAC audio.
    # #### What about AV1?
    my $want_vorbis_p = ($vfmt && $known_formats{$vfmt}->{v} =~ m/^webm/si);
    foreach my $target (@pref_ao) {
      next unless $fmts->{$target};
      my $is_vorbis_p = (($known_formats{$target}->{a} || '') =~ m/^vor/si);
      if (!!$want_vorbis_p == !!$is_vorbis_p) {
        $afmt = $target;
        last;
      }
    }

    # If we got one of the formats and not the other, this isn't going to
    # work. Fall back on pre-muxed.
    #
    if (($vfmt || $afmt) && !($vfmt && $afmt)) {
      print STDERR "$progname: $id: found " .
                   ($vfmt ? 'video-only' : 'audio-only') . ' but no ' .
                   ($afmt ? 'video-only' : 'audio-only') . " formats.\n"
        if ($verbose > 1);
      $vfmt = undef;
      $afmt = undef;
    }

    # If the best unmuxed format is not better resolution than the best
    # pre-muxed format, just use the pre-muxed version.
    #
    # But sometimes that doesn't work, so if we're in an error-retry,
    # maybe don't.
    #
    my $error_toggle = ($total_retries & 1);

    if (!$error_toggle &&
        $mfmt &&
        $vfmt &&
        $known_formats{$vfmt}->{h} <= $known_formats{$mfmt}->{h}) {
      print STDERR "$progname: $id: rejecting $vfmt + $afmt (" .
                   $known_formats{$vfmt}->{w} . " x " .
                   $known_formats{$vfmt}->{h} . ") for $mfmt (" .
                   $known_formats{$mfmt}->{w} . " x " .
                   $known_formats{$mfmt}->{h} . ")\n"
        if ($verbose > 1);
      $vfmt = undef;
      $afmt = undef;
    }


    # At this point, we're definitely intending to mux.
    # But maybe we can't because there's no ffmpeg -- if so, print
    # a warning, then fall back to a lower resolution stream, if possible.
    #
    if ($vfmt && $afmt && !which ($ffmpeg)) {
      if (!$mfmt) {
        error ("$id: \"$ffmpeg\" is not installed, and this video has" .
               " no pre-muxed format.");
      } elsif (!$ffmpeg_warned_p) {
        print STDERR "$progname: WARNING: $id: \"$ffmpeg\" not installed.\n";
        print STDERR "$progname: $id: downloading lower resolution.\n"
          if ($mfmt);
        $ffmpeg_warned_p = 1;
      }
      $vfmt = undef;
      $afmt = undef;
    }
  }

  # If there is a format in the list that we don't know about, warn.
  # This is the only way I have of knowing when new ones turn up...
  #
  {
    my @unk = ();
    foreach my $k (sort keys %$fmts) {
      next if ($k eq 'title' || $k eq 'year' || $k eq 'cipher' ||
               $k eq 'thumb');
      push @unk, $k if (!$known_formats{$k});
    }
    print STDERR "$progname: $id: unknown format " . join(', ', @unk) .
                 "$errorI\n"
      if (@unk);
  }

  if ($verbose > 1) {
    print STDERR "$progname: $id: available formats:\n";
    foreach my $k (sort { ($a =~ m/^\d+$/s ? $a : 0) <=>
                          ($b =~ m/^\d+$/s ? $b : 0) }
                   keys(%$fmts)) {
      next if ($k eq 'title' || $k eq 'year' || $k eq 'cipher' ||
               $k eq 'thumb');
      print STDERR sprintf("%s:   %3d (%s)\n",
                           $progname, $k,
                           ($known_formats{$k}->{desc} || '?') .
                           ($fmts->{$k}->{dashp}
                            ? (' dash' .
                               ((ref ($fmts->{$k}->{url}) eq 'ARRAY')
                                ? ' ' . scalar(@{$fmts->{$k}->{url}}) .
                                  ' segments'
                                : ''))
                            : ''));
    }
  }

  if ($vfmt && $afmt) {
    if ($verbose > 1) {
      my $d1 = $known_formats{$vfmt}->{desc};
      my $d2 = $known_formats{$afmt}->{desc};
      foreach ($d1, $d2) { s@ [av]/?o$@@si; }
      $d1 .= ' dash' if ($fmts->{$vfmt}->{dashp});
      $d2 .= ' dash' if ($fmts->{$afmt}->{dashp});
      print STDERR "$progname: $id: picked $vfmt + $afmt ($d1 + $d2)\n";
    }
    return ($vfmt, $afmt);
  } elsif ($mfmt) {
    # Either not muxing, or muxing not available/necessary.
    my $why = 'picked';
    if (defined($force_fmt) && $force_fmt ne 'mux') {
      error ("$id: format $force_fmt does not exist")
        unless ($fmts->{$force_fmt});
      $why = 'forced';
      $mfmt = $force_fmt;
    }
    print STDERR "$progname: $id: $why $mfmt (" .
                 ($known_formats{$mfmt}->{desc} || '???') . ")\n"
      if ($verbose > 1);

    return ($mfmt);
  } elsif ($force_fmt) {
    return $force_fmt;
  } else {
    error ("$id: No pre-muxed formats; \"$ffmpeg\" required for download");
  }
}



# This is all completely horrible: try to convert the random crap people
# throw into Youtube video titles into something more consistent.
#
# - Aims for "Artist -- Title" instead of various other ways of spelling that.
# - Omits noise phrases like "official music video" and "high quality".
# - Downcases things that appear to be gratuitously in all-caps.
#
# This likely does stupid things on Youtube things that aren't music videos.
#
sub munge_title($) {
  my ($title) = @_;

  return 'Untitled' unless defined($title);

  sub unihex($;) {
    my ($c) = @_;
    $c = hex($c);
    return '' if ($c >= 0xD800 && $c <= 0xDFFF);   # UTF-16 surrogate
    my $s = chr($c);

    # If this is a single-byte non-ASCII character, chr() created a
    # single-byte non-Unicode string.  Assume that byte is Latin1 and
    # expand it to the corresponding unicode character.
    #
    # Test cases:
    #   https://www.vimeo.com/82503761      é  as \u00e9\u00a0
    #   https://www.vimeo.com/123397581     û– as \u00fb\u2013
    #   https://www.youtube.com/watch?v=z9ScJBmEdQw ä  as UTF8 (2 bytes)
    #   https://www.youtube.com/watch?v=eAXmgId3NTQ ø  as UTF8 (2 bytes)
    #   https://www.youtube.com/watch?v=FszEaxrHGTs ∆  as UTF8 (3 bytes)
    #   https://www.youtube.com/watch?v=4ViwSeuWVfE JP as UTF8 (3 bytes)
    #   https://vimeo.com/118261420     Snowman emoji, etc.
    #

    # If this is still a Latin1 string, upgrade it to wide chars.
    if (! utf8::is_utf8($s)) {
      utf8::encode ($s);  # Unpack Latin1 into multi-byte UTF-8.
      utf8::decode ($s);  # Pack multi-byte UTF-8 into wide chars.
    }
    return $s;
  }

  utf8::decode ($title);  # Pack multi-byte UTF-8 back into wide chars.

  # Decode \u and \x syntax.
  $title =~ s/ \\[ux] \{ ([a-z0-9]+)   \} / unihex($1) /gsexi;  # \u{XXXXXX}
  $title =~ s/ \\[ux]   ([a-z0-9]{4})     / unihex($1) /gsexi;  # \uXXXX

  $title =~ s/[\x{2012}-\x{2013}]+/-/gs;  # various dashes
  $title =~ s/[\x{2014}-\x{2015}]+/--/gs; # various long dashes
  $title =~ s/\x{2018}+/\`/gs;      # backquote
  $title =~ s/\x{2019}+/\'/gs;      # quote
  $title =~ s/[\x{201c}\x{201d}]+/\"/gs;  # ldquo, rdquo
  $title =~ s/\`/\'/gs;
  $title =~ s/\s*(\|\s*)+/ - /gs;   # | to -

  $title =~ s/\\//gs; # I think we can just omit other backslashes entirely.

  # spacing, punctuation cleanups
  $title =~ s/^\s+|\s+$//gs;
  $title =~ s/\s+/ /gs;
  $title =~ s/\s+,/,/gs;
  $title =~ s@\s+w/\s+@ with @gs;   # convert  w/ to with
  $title =~ s@(\d)/(?=\d)@$1.@gs;   # convert   / to . in dates
  $title =~ s@/@ - @gs;             # remaining / to delimiter

  $title =~ s/^Youtube -+ //si;
  $title =~ s/ -+ Youtube$//si;
  $title =~ s/^Youtube$//si;
  $title =~ s/ on Vimeo\s*$//si;
  $title =~ s/Broadcast Yourself\.?$//si;

  $title =~ s/\b ( ( (in \s*)? 
                     (
                       HD | TV | HDTV | HQ | 720\s*p? | 1080\s*p? | 4K |
                       High [-\s]* Qual (ity)? 
                     ) |
                     FM(\'s)? |
                     EP s? (?>[\s\.\#]*) (?!\d+) |   # allow "episode" usage
                     MV | M\ -\ V | performance |
                     SXSW ( \s* Music )? ( \s* \d{4} )? |
                     Showcasing \s Artist |
                     Presents |
                     (DVD|CD)? \s+ (out \s+ now | on \s+ (iTunes|Amazon)) |
                     fan \s* made |
                     ( FULL|COMPLETE ) \s+ ( set|concert|album ) |
                     FREE \s+ ( download|D\s*[[:punct:]-]\s*L ) |
         Live \s+ \@ \s .*
                   )
                   \b \s* )+ //gsix;

  $title =~ s/\b (The\s*)? (Un)?Off?ici[ae]le?
                 ( [-\s]* 
                   ( Video | Clip | Studio | Music | Audio | Stereo | Lyric )s?
                 )+
              \b//gsix;
  $title =~ s/\b Music ( [-\s]* ( Video | Clip )s?)+ \b//gsix;

  $title =~ s/\.(mp[34]|m4[auv]|mov|mqv|flv|wmv)\b//si;
  $title =~ s/\b(on\s*)? [A-Za-z-0-9.]+\.com $//gsix;       # kill trailing urls
  $title =~ s/\b(brought to you|made possible) by .*$//gsi; # herp derpidy derp
  $title =~ s/\bour interview with\b/ interviews /gsi;      # re-handled below
  $title =~ s/\b(perform|performs|performing)\b/ - /gsi;    # other delimiters
  $title =~ s/\b(play   |plays   |playing   )\b/ - /gsi;    # other delimiters
  $title =~ s/\s+ [\|+]+  \s+                  / - /gsi;    # other delimiters
  $title =~ s/!+/!/gsi;                 # yes, I'm excited too
  $title =~ s/\s+-+[\s-]*\s/ - /gsi;    # condense multiple delimiters into one

  $title =~ s/\s+/ /gs;

  # Lose now-empty parens.
#  1 while ($title =~ s/\(\s*\)//gs);
#  1 while ($title =~ s/\[\s*\]//gs);
#  1 while ($title =~ s/\{\s*\}//gs);

  # Lose now-empty parens.
  #
  # Any combination of these words is an empty phrase.
  my ($empty_phrase)
    = q/
        \s*(
          the | new | free | amazing | (un)?off?ici[ae]le? | 
          on | iTunes | Amazon | [\s[:punct:]]+ | version |
          cc | song | video | audio | band | source | field |
          extended | mix | remix | edit | stream | uncut | single |
          track | to be | released? | out | now |
          teaser | trailer | videoclip
        )?\s*
      /
  ;
  # Jesus fuck, youtube, how much more diarrhea can there be??
  # None.  None more diarrhea.

  1 while ($title =~ s/\(($empty_phrase)*\)//gsix); # Check all
  1 while ($title =~ s/\[($empty_phrase)*\]//gsix); # three
  1 while ($title =~ s/\{($empty_phrase)*\}//gsix); # paren styles.

  $title =~ s/[-;:,\s]+$//gs;            # trailing crap
  $title =~ s/\bDirected by\b/Dir./gsi;  # "Directed By" is not "A by B"
  $title =~ s/\bProduced by\b/Prod./gsi; # "Produced By" is not "A by B"


  # Guess the title and artist by applying a series of regexes, in order,
  # Starting with    the most sensitive attempts,
  # slowly moving to the most stable    attempts,
  # and ending with  the most desperate attempts.

  my $obrack = '[\(\[\{]';   # for readability; matches the 3 major brackets.
  my $cbrack = '[\)\]\}]';   # /$obrack $cbrack/ matches "[ }".  close enough.


  my ($artist, $track, $junk) = (undef, undef, '');

  ($title, $junk) = ($1, $2)      # TITLE (JUNK)
    if ($title =~ m/^(.*)\s+$obrack+ (.*) $cbrack+ $/six);

  ($title, $junk) = ($1, "$3 $junk")  # TITLE (Dir. by D) .*
    if ($title =~ m/^ ( .+? )
                      ($obrack+|\s)\s* ((Dir|Prod)\. .*)$/six);


  ($track, $artist) = ($1, $2)      # TRACK performed by ARTIST
    if (!$artist &&       # TRACK by ARTIST
        $title =~ m/^ ( .+? ) \b
                      (?: performed \s+ )? by \b ( .+ )$/six);

  ($artist, $track) = ($1, $2)      # ARTIST performing TRACK
    if (!$artist &&
        $title =~ m/^ ( .+? ) \b (?: plays | playing | performs? |
                                     performing )
                    \b ( .+ )$/six);

  ($artist, $track) = ($1, "\L$2\E $3")   # ARTIST talks about HIMSELF
    if (!$artist &&                       #        ^^^^^^^^^^^^^^^^^^^ = TRACK
        $title =~ m/^ ( .+? ) \b 
                      \(? \s* (interview|talks about) \s* \)?
                      \b \s* ( .+ ) $/six);

  ($artist, $track) = ($2, "interview by $1")  # IDIOT interviews ARTIST
    if (!$artist &&                            # TRACK = interview by IDIOT
        $title =~ m/^ ( .+? ) \b
                      (?: interviews | interviewing )
                      \b ( .+ )$/six);

  ($track, $artist) = ($1, $2)        # "TRACK" ARTIST
    if (!$artist &&
        $title =~ m/^ \" ( .+? ) \" [,\s]+ ( .+ )$/six);

  ($artist, $track, $junk) = ($1, $2, "$3 $junk") # ARTIST "TRACK" JUNK
    if (!$artist &&
        $title =~ m/^ ( .+? ) [,\s]+ \" ( .+ ) \" ( .*? ) $/six);


  ($track, $artist) = ($1, $2)        # 'TRACK' ARTIST
    if (!$artist &&
        $title =~ m/^ \' ( .+? ) \' [,\s]+ ( .+ )$/six);

  ($artist, $track, $junk) = ($1, $2, "$3 $junk") # ARTIST 'TRACK' JUNK
    if (!$artist &&
        $title =~ m/^ ( .+? ) [,\s]+ \' ( .+ ) \' ( .*? ) $/six);


  ($artist, $track) = ($1, $2)        # ARTIST -- TRACK
    if (!$artist &&
        $title =~ m/^ ( .+? ) \s* --+ \s* ( .+ )$/six);

  ($artist, $track) = ($1, $2)        # ARTIST: TRACK
    if (!$artist &&
        $title =~ m/^ ( .+? ) \s* :+  \s* ( .+ )$/six);


  ($artist, $track) = ($1, $2)        # ARTIST-- TRACK
    if (!$artist &&
        $title =~ m/^ ( .+? )     --+ \s* ( .+ )$/six);

  ($artist, $track) = ($1, $2)        # ARTIST - TRACK
    if (!$artist &&
        $title =~ m/^ ( .+? ) \s+ -   \s+ ( .+ )$/six);

  ($artist, $track) = ($1, $2)        # ARTIST- TRACK
    if (!$artist &&
        $title =~ m/^ ( .+? )     -+  \s* ( .+ )$/six);

  ($artist, $track) = ($1, $2)        # ARTIST live at LOCATION
    if (!$artist &&                   #        ^^^^^^^^^^^^^^^^ = TITLE
        $title =~ m/^ ( .+? ) (live \s* (at|@) .+ )$/six);


  ($artist, $junk) = ($1, "$2 $junk") # more JUNK in $artist?
    if ($artist &&
        $artist =~ m/^ ( .+? ) \s+ -+ \s+ ( .+? ) $/six);

  ($track, $junk) = ($1, "$2 $junk")  # live at LOCATION in $track?
    if ($artist && $track &&
        $track =~ m/^ ( .+? ) \s+ $obrack? ( live \s* (at|@) .* )$/six);
                               #  ^^^^^^^---closing paren to be chopped below


  # You will find my junk requires extra scrubbing today.
  if ($junk) {
    $junk =~ s/^\s+|\s+$//gs;

    # disallow  junk consisting of all punctuation,
    # but allow junk consisting of all digits or foreign chars.
    $junk = '' if $junk =~ m/^[[:punct:]\s]+$/i;

    # de-parenthesize
    $junk =~ s/^ [\(\[\{\s]+ (.+?) [\)\]\}\s]+ $/$1/six;

    # Stahhhhhp...
    $junk = '' if $junk =~ m/ ^ \s* ( (un)?off?ici[ae]le? | video ) \s* $/six;
  }


  # Thoroughly wash fruits and vegetables before eating.
  foreach my $s ($artist, $track, $junk, $title) {
    next unless $s;

    # Allow leading and trailing "." here.
    # Otherwise, it messes up
    #   Seasons       -- ...Of Our Discontent
    #   Jordin Sparks -- S.O.S. (Let The Music Play)
    #   R.E.M.        -- Automatic for the People
    $s =~ s/^ [-\s\"\'\`\|,;:]+ |
              [-\s\"\'\`\|,;:]+ $ //gsx;

    # Remove easily-found unbalanced parens.
    #
    #   "TRACK (by ARTIST)" becomes "ARTIST) - TRACK (".
    #   Cleaning unbalanced parens as below fixes that,
    #   but messes up the band name "Sunn O)))".  Oh well.
        next if $s =~ m/^Sunn [0O]\)\)\)?$/;

    # I use defined() and /e to avoid undef warning for $1 replacement.
    1 while ($s =~ s/^ ([^\(]*?) \) / defined($1)?$1:"" /gsex); # Leading
    1 while ($s =~ s/^ ([^\[]*?) \] / defined($1)?$1:"" /gsex); # close
    1 while ($s =~ s/^ ([^\{]*?) \} / defined($1)?$1:"" /gsex); # brackets.

    1 while ($s =~ s/  \( ([^\)]*) $/ defined($1)?$1:"" /gsex); # Trailing
    1 while ($s =~ s/  \[ ([^\]]*) $/ defined($1)?$1:"" /gsex); # open
    1 while ($s =~ s/  \{ ([^\}]*) $/ defined($1)?$1:"" /gsex); # brackets.
    # The above does NOT correct, for instance, "ARTIST - TRACK (2014) )".
    # Maybe I'll fix that later; I do love the burden of inhuman toil.


    # If there are no lower case letters,
    # capitalize all fully-upper-case words (with some allowances).
    my $okupper =
      # There're fewer good all-caps artists than diarrhea words.
      # Just list them.
      # Ironically, the story of the band ALL CAPS
      # is too stupid to warrant including them.
      'NIN|MS\s?MR|RJD2|HNN|'            # ARTISTS
      .'MF\|?\s?MB\|?|'
      .'STRFKR|EMA|UDG|BDRG|HOTT MT|'
      .'RAW|MNDR|HTRK|SPC ECO|RTX|2NE1|'
      .'BT|INXS|THX|SNL|CTRL|NSFW|DNA|'

      .'POB|JPL|LNX|' # are these DJs? abbreviations?

      .'YKWYR|MFN|TV|ICHRU|AAA|OK|MJ|'   # TRACKS
      .'I\s?L\s?U|TKO|SWAG|'
      .'LAX|ADHD|BTR'
    ;

    $s =~ s/\b([[:upper:]])([[:upper:]\d\']+)\b/$1\L$2/gsi # Capitalize,
      unless ($s =~ m/[a-z]/s      ||                     # unless lowercase or
              $s =~ m/^($okupper)$/                       # specifically okayed.
             )
    ;
  }

  # THIS IS IT!
  $title  = "$artist - $track" if $artist;
  $title .= " ($junk)"         if $junk;


  # Final cleanups, to prevent bad filenames
  $title =~ s@\s*[/:]+\s*@ - @gs;   # no colons or slashes
  $title =~ s/^ - | - $//gs;        # leading, trailing delimeters
  $title =~ s/^\s+|\s+$//gs;        # leading, trailing space
  $title =~ s/\s+/ /gs;             # multiple spaces

  # Don't allow the title to begin with "." or it writes a hidden file.
  # And dash causes a stdout dump.
  $title =~ s/^[-.,\s]+//gs;

  # Oh FFS. I don't know what's going on here, but on MacOS 10.13.6 we
  # sometimes get "Illegal byte sequence" from open() when the UTF-8
  # in the file name still has Latin1 in it somehow, e.g. when it
  # somehow still has &oslash; as \370 instead of \303\270.
  #
  # This maybe has to do with Perl thinking "UTF-8" means "standard"
  # and "utf8" means "anything goes"?
  #
  # The following round trip seems to clean it up, maybe.
  #
  $title = Encode::encode('UTF-8', $title);
  $title = Encode::decode('UTF-8', $title);

  return $title || "Untitled";
}


sub sanity_check_title($$$$) {
  my ($title, $url, $body, $where) = @_;
  errorI ("no title: $where, $url\n\n$body")
    if (!$title || $title =~ m/^untitled$/si);
}


# Does any version of the file exist with the usual video suffixes?
# Returns the one that exists.
#
sub file_exists_with_suffix($;) {
  my ($f) = @_;
  foreach my $ext (@video_extensions) {
    my $ff = "$f.$ext";
    # No, don't do this.
    # utf8::encode($ff);   # Unpack wide chars into multi-byte UTF-8.
    return ($ff) if -f ($ff);
  }
  return undef;
}


# There are so many ways to specify URLs of videos... Turn them all into
# something sane and parsable.
#
# Duplicated in youtubefeed.

sub canonical_url($;) {
  my ($url) = @_;

  # Forgive pinheaddery.
  $url =~ s@&amp;@&@gs;
  $url =~ s@&amp;@&@gs;
  $url =~ s/^\s+|\s+$//gs;

  # Add missing "https:"
  $url = "https://$url" unless ($url =~ m@^https?://@si);

  # Rewrite youtu.be URL shortener.
  $url =~ s@^https?://([a-z]+\.)?youtu\.be/@https://youtube.com/v/@si;

  # Youtube's "attribution links" don't encode the second URL:
  # there are two question marks. FFS.
  # https://www.youtube.com/attribution_link?u=/watch?v=...&feature=...
  $url =~ s@^(https?://[^/]*\byoutube\.com/)attribution_link\?u=/@$1@gsi;

  # Rewrite Vimeo URLs so that we get a page with the proper video title:
  # "/...#NNNNN" => "/NNNNN"
  $url =~ s@^(https?://([a-z]+\.)?vimeo\.com/)[^\d].*\#(\d+)$@$1$3@s;

  $url =~ s@^http:@https:@s;  # Always https.

  my ($id, $site, $playlist_p);

  # Youtube /view_play_list?p= or /p/ URLs.
  if ($url =~ m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/
                (?: view_play_list\?p= |
                    p/ |
                    embed/p/ |
                    # We used to need to strip the leading PL, now we don't?
                    # .*? [?&] list=(?:PL)? |
                    # embed/videoseries\?list=(?:PL)?
                    .*? [?&] list= |
                    embed/videoseries\?list=
                )
                ([^<>?&,\#]+) ($|[&\#]) @sx) {
    ($site, $id) = ($1, $2);
    $url = "https://www.$site.com/view_play_list?p=$id";
    $playlist_p = 1;

  # Youtube "/verify_age" URLs.
  } elsif ($url =~
           m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/+
       .* next_url=([^&\#]+)@sx ||
           $url =~ m@^https?://(?:[a-z]+\.)?google\.com/
                     .* service = (youtube)
                     .* continue = ( http%3A [^?&\#]+)@sx ||
           $url =~ m@^https?://(?:[a-z]+\.)?google\.com/
                     .* service = (youtube)
                     .* next = ( [^?&\#]+)@sx
          ) {
    $site = $1;
    $url = url_unquote($2);
    if ($url =~ m@&next=([^&]+)@s) {
      $url = url_unquote($1);
      $url =~ s@&.*$@@s;
    }
    $url = "https://www.$site.com$url" if ($url =~ m@^/@s);

  # Youtube /watch/?v= or /watch#!v= or /v/ or /shorts/ URLs.
  } elsif ($url =~ m@^https?:// (?:[a-z]+\.)?
                     (youtube) (?:-nocookie)? (?:\.googleapis)? \.com/+
                     (?: (?: watch/? )? (?: \? | \#! ) v= |
                         v/ |
                         shorts/ |
                         embed/ |
                         .*? &v= |
                         [^/\#?&]+ \#p(?: /[a-zA-Z\d] )* /
                     )
                     ([^<>?&,\'\"\#]+) ($|[?&#]) @sx) {
    ($site, $id) = ($1, $2);
    $url = "https://www.$site.com/watch?v=$id";

  # Youtube "/user" and "/profile" URLs.
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/
                     (?:user|profile).*\#.*/([^&/\#]+)@sx) {
    $site = $1;
    $id = url_unquote($2);
    $url = "https://www.$site.com/watch?v=$id";
    error ("unparsable user next_url: $url") unless $id;

  # Vimeo /NNNNNN URLs
  # and player.vimeo.com/video/NNNNNN
  # and vimeo.com/m/NNNNNN

  # Apr 2022: saw this new weird URL: https://vimeo.com/684758548/1eacbca96e
  # I tried adding that to the ID, and with a colon, and it doesn't work.

  } elsif ($url =~
           m@^https?://(?:[a-z]+\.)?(vimeo)\.com/(?:video/|m/)?(\d+(?:[:/][a-f\d]{10})?)@s) {
    ($site, $id) = ($1, $2);
    $id =~ s@/@:@gs;
    $url = "https://$site.com/$id";

  # Vimeo /videos/NNNNNN URLs.
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(vimeo)\.com/.*/videos/(\d+(?:[:/][a-f\d]{10})?)@s) {
    ($site, $id) = ($1, $2);
    $id =~ s@/@:@gs;
    $url = "https://$site.com/$id";

  # Vimeo /channels/name/NNNNNN URLs.
  # Vimeo /ondemand/name/NNNNNN URLs.
  } elsif ($url =~
           m@^https?://(?:[a-z]+\.)?(vimeo)\.com/[^/?&\#]+/[^/?&\#]+/(\d+)@s) {
    ($site, $id) = ($1, $2);
    $url = "https://$site.com/$id";

  # Vimeo /album/NNNNNN/video/MMMMMM
  } elsif ($url =~
           m@^https?://(?:[a-z]+\.)?(vimeo)\.com/album/\d+/video/(\d+)@s) {
    ($site, $id) = ($1, $2);
    $url = "https://$site.com/$id";

  # Vimeo /moogaloop.swf?clip_id=NNNNN
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(vimeo)\.com/.*clip_id=(\d+)@s) {
    ($site, $id) = ($1, $2);
    $url = "https://$site.com/$id";

  # Tumblr /video/UUU/NNNNN
  } elsif ($url =~
        m@^https?://[-_a-z\d]+\.(tumblr)\.com/video/([^/?&\#]+)/(\d{8,})/@si) {
    my $user;
    ($site, $user, $id) = ($1, $2, $3);
    $site = lc($site);
    $url = "https://$user.$site.com/post/$id";

  # Tumblr /post/NNNNN
  } elsif ($url =~ m@^https?://([-_a-z\d]+)\.(tumblr)\.com
                     /.*?/(\d{8,})(/|$)@six) {
    my $user;
    ($user, $site, $id) = ($1, $2, $3);
    $site = lc($site);
    $url = "https://$user.$site.com/post/$id";

  # Instagram /p/NNNNN
  } elsif ($url =~
           m@^https?://([-_a-z\d]+\.)?(instagram)\.com/p/([^/?&\#]+)@si) {
    (undef, $site, $id) = ($1, $2, $3);
    $site = lc($site);
    $url = "https://www.$site.com/p/$id";

  # Twitter /USER/status/NNNNN
  } elsif ($url =~ m@^https?://([-_a-z\d]+\.)?(twitter)\.com/([^/?&\#]+)
                     /status/([^/?&\#]+)@six) {
    my $user;
    (undef, $site, $user, $id) = ($1, $2, $3, $4);
    $site = lc($site);
    $url = "https://$site.com/$user/status/$id";

  } else {
    error ("unparsable URL: $url");
  }

  #error ("bogus URL: $url") if ($id =~ m@[/:?]@s);

  return ($url, $id, $site);
}


# Having downloaded a video file and an audio file, combine them and delete
# the two originals.
#
sub mux_downloaded_files($$$$$$$) {
  my ($id, $url, $title, $v1, $v2, $muxed_file, $progress_p) = @_;

  my $video_file = $v1->{file};
  my $audio_file = $v2->{file};

  if (! defined($muxed_file)) {
    $muxed_file = $video_file;
    $muxed_file =~ s@\.(audio-only|video-only)\.@.@gs;
    $muxed_file =~ s@ [^\s\[\]]+(\].)@$1@gs;
  }

  error ("$id: mismunged filename $muxed_file")
    if ($muxed_file eq $audio_file || $muxed_file eq $video_file);
  error ("$id: exists: $muxed_file (1)") if (-f $muxed_file);

  error ("$video_file does not exist") unless (-f $video_file);
  error ("$audio_file does not exist") unless (-f $audio_file);
  my @cmd = ($ffmpeg,
             "-hide_banner",
             "-loglevel", "info",  # Show progress

             '-i', $video_file,
             '-i', $audio_file,
             '-map', '0:v:0', # from file 0, video track 0
             '-map', '1:a:0', # from file 1, audio track 0
             '-shortest');  # they should be the same length already

  my $desc = 'merging';
  my $expect_same_size_p = 1;

  if ($webm_transcode_p &&
      ($v1->{content_type} =~ m/(webm|av1)$/si ||
       $v2->{content_type} =~ m/(webm|av1)$/si)) {
    # We are transcoding from WebM/Vorbis to MP4/AAC. It's slow.
    $desc = 'transcoding';
    $muxed_file =~ s@\.[^./]+$@.mp4@gsi;
    $expect_same_size_p = 0;
    push @cmd, ('-c:v',   'libx264',  # video codec
                '-profile:v', 'high',   # h.264 feature set allowed
                '-preset',  'veryslow', # maximum effort on compression
                '-crf',   '22',   # h.264 quality (18 is high,
                '-pix_fmt', 'yuv420p',  # 22 seems to match WebM)
              # '-acodec',  'aac',    # encode audio as AAC
                '-acodec',  'libfdk_aac', #  higher quality encoder
                '-b:a',   '192k',   # audio bitrate
                '-movflags',  'faststart',  # Move index to front
                # Avoid "Too many packets buffered" with sparse audio frames.
                '-max_muxing_queue_size', '1024',
               );
  } else {
    push @cmd, ('-vcodec', 'copy',  # no re-encoding
                '-acodec', 'copy');
  }

  # If there's no extension on the "--out" file, default to MP4.
  push @cmd, ('-f', 'mp4') unless ($muxed_file =~ m@\.[^/]+$@s);
  push @cmd, $muxed_file;

  $rm_f{$muxed_file} = 1;

  if ($verbose == 1) {
    print STDERR "$progname: $desc audio and video...\n";
  } elsif ($verbose > 1) {
    my @c2 = @cmd;
    print STDERR "$progname: $id: exec: $desc: " .
                 join(' ', map { if (m![^-._,:a-z\d/@+=]!s) {
                                   s%([\'\!])%\\$1%gsi;
                                   $_ = "'$_'";
                                 }
                                 $_;
                               } @c2) . "\n";
  }


  {
    my $result = '';
    my ($in, $out, $err);
    $err = Symbol::gensym;
    my $pid = eval { open3 ($in, $out, $err, @cmd) };
    if (!$pid) {
      $err = "exec: $cmd[0]: $!";
    } else {
      close ($in);
      close ($out);

      my ($dur, $input_bytes);
      my $start_time = time();

      if ($progress_p) {
        my $s1 = (stat($audio_file))[7] || 0;
        my $s2 = (stat($video_file))[7] || 0;
        $input_bytes = $s1 + $s2;
      }

      # The stderr output from ffmpeg sometimes uses \n and sometimes \r
      # so we have to use sysread here and split manually instead of
      # while (<$err>) or the whole stderr buffers.
      #
      my $bufsiz = 16384;
      while (1) {
        my ($rin, $win, $ein, $rout, $wout, $eout);
        $rin = $win = $ein = '';
        vec ($rin, fileno($err), 1) = 1;
        $ein = $rin | $win;
        my $nfound = select ($rout = $rin, $wout = $win, $eout = $ein, undef);
        my $chunk = '';
        my $size = sysread ($err, $chunk, $bufsiz);
        last if ($nfound && !$size);   # closed
        $result .= $chunk;
        if ($progress_p || $verbose > 2) {
          # Let's just assume ffmpeg never splits writes mid-line.
          # (Actually "rarely" is as good as "never")
          $chunk =~ s/\r\n?/\n/gs;
          foreach my $line (split(/\n/, $chunk)) {
            print STDERR "  <== $line\n" if ($verbose > 2);

            # ffmpeg doesn't provide the total number of frames anywhere,
            # so we have to go by timestamp instead:
            #
            # Input #0, ...
            #   Duration: 00:03:26.99, start: 0.000000, bitrate: 3005 kb/s
            # ...
            #  frame= 3378 fps= 88 q=30.0 size=    7680kB time=00:00:55.21 ...
            #
            if (!$dur &&
                $line =~ m/^\s*Duration:\s+(\d+):(\d\d):(\d\d(\.\d+)?)\b/s) {
              $dur = $1*60*60 + $2*60 + $3;
            } elsif ($dur && $progress_p &&
                     $line =~ m/^\s* frame= .* \b
                                time= \s* (\d+):(\d\d):(\d\d(\.\d+)?)/sx) {
              my $cur = $1*60*60 + $2*60 + $3;
              my $elapsed = time() - $start_time;
              my $bps = $elapsed ? ($input_bytes * 8 / $elapsed) : 0;
              draw_progress ($cur / $dur, $bps, 0);
            }
          }
        }
      }

      draw_progress (1, 0, 1) if ($dur && $progress_p);

      # The stderr from the subprocess has hit EOF, so the pid should be
      # dead momentarily.

      waitpid ($pid, 0);
      my $exit_value  = $? >> 8;
      my $signal_num  = $? & 127;
      my $dumped_core = $? & 128;

      $err = undef;
      $err = "$id: $cmd[0]: core dumped!" if ($dumped_core);
      $err = "$id: $cmd[0]: signal $signal_num!" if ($signal_num);
      $err = "$id: $cmd[0]: exited with $exit_value!" if ($exit_value);
    }

    if ($err) {
      if (-f $muxed_file) {
        print STDERR "$progname: rm \"$muxed_file\"\n" if ($verbose > 1);
        unlink ($muxed_file);  # It's not a download, and it's broken.
      }

      my @L = split(/(?:\r?\n)+/, $result);
      $result = join ("\n", @L[-5 .. -1])     # only last 5 lines
        if (@L > 5);
      if ($result) {
        $result =~ s/^/$cmd[0]: /gm;
        $err .= "\n\n$result\n";
      }
      error ($err);
    }
  }

  my $s1 = (stat($audio_file))[7] || 0;
  my $s2 = (stat($video_file))[7] || 0;
  my $s3 = (stat($muxed_file))[7] || 0;

  $s1 = $s1 + $s2;
  my $diff = $s1 * 0.05;          # 5% of audio+video seems safe & sane
  if ($s3 > 8*1024*1024 &&        # File is non-tiny
      ($expect_same_size_p &&
       (($s3 < ($s1 - $diff)) ||    # muxed is less than audio+video - N%
        ($s3 > ($s1 + $diff))))) {  # muxed is more than audio+video + N%
    my $s1b = fmt_size ($s1);
    my $s3b = fmt_size ($s3);
    print STDERR "$progname: WARNING: " .
           "$id: $cmd[0] wrote a short file! Got $s3b, expected $s1b" .
           " ($s1 - $s3 = $diff)\n";
  }

  if ($verbose < 3) {
    foreach my $f ($audio_file, $video_file) {
      if (-f $f) {
        print STDERR "$progname: rm \"$f\"\n" if ($verbose > 1);
        unlink $f;
      }
    }
  }

  delete $rm_f{$muxed_file};  # Succeeded, keep file.

  write_file_metadata_url ($muxed_file, $id, $url);

  if ($verbose > 0) {
    my ($w, $h, $size, $abr) = video_file_size ($muxed_file);
    $size = -1 unless $size;
    my $ss = fmt_size ($size);
    $ss .= ", $w x $h" if ($w && $h);
    print STDERR "$progname: wrote   \"$muxed_file\"\n";
    print STDERR "$progname:         $ss\n";
  }
}


sub content_type_ext($;) {
  my ($ct) = @_;
  if    ($ct =~ m@/(x-)?flv$@si)  { return 'flv';  }
  elsif ($ct =~ m@/(x-)?webm$@si) { return 'webm'; }
  elsif ($ct =~ m@/(x-)?3gpp$@si) { return '3gpp'; }
  elsif ($ct =~ m@/(x-)?av1$@si)  { return 'av1';  }
  elsif ($ct =~ m@/quicktime$@si) { return 'mov';  }
  elsif ($ct =~ m@^audio/mp4$@si) { return 'm4a';  }
  elsif ($ct =~ m@^audio/ec3$@si) { return 'ec3';  }
  elsif ($ct =~ m@^audio/ac3$@si) { return 'ac3';  }
  else                            { return 'mp4';  }
}


sub load_formats($$) {
  my ($url, $size_p) = @_;
  my ($url2, $id, $site) = canonical_url ($url);
  return ($site eq 'youtube'   ? load_youtube_formats   ($id, $url, $size_p):
          $site eq 'vimeo'     ? load_vimeo_formats     ($id, $url, $size_p) :
          $site eq 'tumblr'    ? load_tumblr_formats    ($id, $url, $size_p) :
          $site eq 'instagram' ? load_instagram_formats ($id, $url, $size_p) :
          $site eq 'twitter'   ? load_twitter_formats   ($id, $url, $size_p) :
          error ("$id: unknown site: $site"));
}


my %fmt_all_retry_kludge;

sub download_video_url($$$$$$$$$$$$);
sub download_video_url($$$$$$$$$$$$) {
  my ($url, $title, $prefix, $outfile, $size_p,
      $list_p, $list_idx, $list_count,
      $bwlimit, $progress_p, $force_fmt, $max_size) = @_;

  $error_whiteboard = ''; # reset per-URL diagnostics
  $progress_ticks = 0;    # reset progress-bar counters
  $progress_time = 0;

  # Pack multi-byte UTF-8 back into wide chars.
  utf8::decode ($title)  if defined($title);
  utf8::decode ($prefix) if defined($prefix);

  foreach ($title, $prefix) {
    s@\s*[/:]+\s*@ - @gs if $_;  # no colons or slashes
    s/^\s+|\s+$//gs if $_;
  }

  my ($id, $site);
  ($url, $id, $site) = canonical_url ($url);

  # If downloading a playlist, recurse.
  #
  if ($url =~ m@view_play_list@s) {
    error ("--out does not work with playlists") if ($outfile);
    return download_youtube_playlist ($id, $url, $title, $prefix, $size_p,
                                      $list_p, $bwlimit, $progress_p,
                                      $force_fmt, $max_size);
  }

  # Fuck you, Twitter. Handle links to Youtube inside twits.
  # If there is both a Youtube link and Twitter-hosted video,
  # we ignore the latter.
  #
  if ($site eq 'twitter') {
    my ($http, $head, $body) = get_url ($url);
    check_http_status ($id, $url, $http, 1);
    if ($body =~ m@\b ( https?://( youtu\.be | [^a-z/]+\.youtube\.com )
                   / [^\s\"\'<>]+ ) @six) {
      ($url, $id, $site) = canonical_url ($1);
    }
  }


  # Handle --list for playlists.
  #
  if ($list_p) {
    if ($list_p > 1) {
      my $t2 = ($prefix ? "$prefix $title" : $title);
      print STDOUT "$id\t$t2\n";
    } else {
      print STDOUT "https://www.$site.com/watch?v=$id\n";
    }
    return;
  }


  # Though Tumblr and Twitter can host their own videos, much of the time
  # there is just an embedded Youtube video instead.
  #
  if ($site eq 'tumblr' || $site eq 'twitter') {
    my ($http, $head, $body) = get_url ($url);
    check_http_status ($id, $url, $http, 1);
    if ($body =~ m@ \b ( https?:// (?: [a-z]+\. )?
                    youtube\.com/
                    [^\"\'<>]*? (?: embed | \?v= )
                    [^\"\'<>]+ )@six) {
      ($url, $id, $site) = canonical_url (html_unquote ($1));
    }
  }


  my $suf = (" [" . $id .
             ($force_fmt && $force_fmt ne 'mux' ? " $force_fmt" : "") .
             "]");

  if (! ($size_p || $list_p)) {

    # If we're writing with --suffix, we can check for an existing
    # file before knowing the title of the video.  Check for a file
    # with "[this-ID]" in it.  (The quoting rules of perl's "glob"
    # function are ridiculous and confusing, so let's do it the hard
    # way instead.)
    #
    opendir (my $dir, '.') || error ("readdir: $!");
    foreach my $f (readdir ($dir)) {
      if ($f =~ m/\Q$suf\E/s) {
        exit (1) if ($verbose <= 0); # Skip silently if --quiet.
        error ("$id: exists: $f (2)");
      }
    }
    closedir $dir;

    if (defined($outfile)) {
      error ("$id: exists: $outfile (3)") if (-f $outfile);

    } elsif (defined($title)) {
      # If we already have a --title, we can check for the existence of the
      # file before hitting the network.  Otherwise, we need to download the
      # video info to find out the title and thus the file name.
      #
      my $t2 = ($prefix ? "$prefix $title" : $title);
      my $o = (file_exists_with_suffix ("$t2") ||
               file_exists_with_suffix ("$t2$suf") ||
               file_exists_with_suffix ("$title") ||
               file_exists_with_suffix ("$title$suf"));
      if ($o) {
        exit (1) if ($verbose <= 0); # Skip silently if --quiet.
        error ("$id: exists: $o (4)");
      }
    }
  }


  # Videos can come in multiple resolutions, and sometimes with audio and
  # video in separate URLs. Get the list of all possible downloadable video
  # formats.
  #
  my $fmts = load_formats ($url, $size_p);

  # Set the title unless it was specified on the command line with --title.
  #
  if (!defined($title) && defined($fmts)) {
    $title = munge_title ($fmts->{title});
    #sanity_check_title ($title, $url, '[fmts]', 'download_video_url');

    # Add the year to the title unless there's a year there already.
    #
    if ($title !~ m@ \(\d{4}\)@si) {  # skip if already contains " (NNNN)"
      my $year = ($fmts->{year}      ? $fmts->{year}          :
                  $site eq 'youtube' ? get_youtube_year ($id) :
                  $site eq 'vimeo'   ? get_vimeo_year ($id)   : undef);
      if ($year &&
          $year  != (localtime())[5]+1900 &&   # Omit this year
          $title !~ m@\b$year\b@s) {     # Already in the title
        $title .= " ($year)";
      }
    }

    # Now that we've hit the network and determined the real title, we can
    # check for existing files on disk.
    #
    if (!defined($outfile) &&
        (! ($size_p || $list_p))) {
      my $t2 = ($prefix ? "$prefix $title" : $title);
      my $o = (file_exists_with_suffix ("$t2") ||
               file_exists_with_suffix ("$title") ||
               file_exists_with_suffix ("$title") ||
               file_exists_with_suffix ("$title$suf"));
      if ($o) {
        exit (1) if ($verbose <= 0); # Skip silently if --quiet.
        error ("$id: exists: $o (5)");
      }
    }
  }


  # Now that we have the video info, decide what to download.
  # If we're doing --fmt all, this is all of them.
  # Otherwise, it's either one URL or two (audio + video mux).
  #
  my @targets = pick_download_format ($id, $site, $url, $force_fmt, $fmts,
                                      $max_size)
    if (defined ($fmts));
  my @pair = (@targets == 2 && $force_fmt ne 'all' ? @targets : ());

  if ($size_p && @pair) {
    # With --size, we only need to examine the first pair of the mux.
    @targets = ($pair[0]) if ($pair[0]);
    @pair = ();
  }

  $append_suffix_p = 1
    if (!$size_p && defined($force_fmt) && $force_fmt eq 'all');

  my @outfiles = ();
  if (defined($outfile) && @pair) {
    foreach (@pair) {
      my $f = sprintf("%s-%08x", $outfile, rand(0xFFFFFFFF));
      push @outfiles, $f;
    }
  }

  foreach my $target (@targets) {
    error ("$id: no target") unless defined($target);
    my $fmt   = $fmts->{$target};
    my $ct    = $fmt->{content_type};
    my $w     = $fmt->{width};
    my $h     = $fmt->{height};
    my $abr   = $fmt->{abr};
    my $size  = $fmt->{size};
    my $url2  = $fmt->{url};
    my $dashp = $fmt->{dashp};

    # If we are doing "--fmt all" and we get an error downloading one of
    # them, don't retry *all* of them.
    next if ($fmt_all_retry_kludge{$target});

    $error_whiteboard .= "fmt $target: $url2\n\n";

    if ($size_p) {
      if (! (($w && $h) || $abr)) {

        # On a non-playlist, "--size --size" or "--ping" means guess the size
        # from the format rather than downloading the first part of the video
        # to get the exact resolution.  Way faster, less bandwidth.
        #
        # #### Actually we can't guess the size because we don't have access
        # to $known_formats here.  Oh well.  So we print a size of "?x?".
        #
        if ($size_p eq 1) {
          my ($w2, $h2, $s2, $a2) =
            video_url_size ($id, $url2, $ct, $bwlimit,
                            (defined($force_fmt) && $force_fmt eq 'all'
                             ? 1 : 0));
          $w    = $w2 if $w2;
          $h    = $h2 if $h2;
          $size = $s2 if $s2;
          $abr  = $a2 if $a2;
        }
      }

      my $ii = $id . (@targets == 1 ? '' : ":$target");
      my $ss = fmt_size ($size);
      my $wh = ($w && $h
                ? "${w} x ${h}"
                : ($abr ? "$abr  " : ' ?x?'));
      my $t2 = ($prefix ? "$prefix $title" : $title);
      print STDOUT "$ii\t$wh\t$ss\t$t2\n";

    } else {

      $suf = ($append_suffix_p
              ? (" [" . $id .
                 ((@targets == 1 &&
                   !(defined($force_fmt) && $force_fmt eq 'all'))
                  ? '' : " $target") .
                 "]")
              : (@pair
                 ? ($target == $pair[0] ? '.video-only' : '.audio-only')
                 : ''));

      my $file = ($prefix ? "$prefix $title" : $title) . $suf;
      $ct =~ s/;.*$//s;
      $file .= '.' . content_type_ext($ct);

      my $ftitle = $file;

      $file = (@pair
               ? ($target == $pair[0] ? $outfiles[0] : $outfiles[1])
               : $outfile)
        if (defined($outfile));

      $fmt->{file} = $file;

      if (-f $file) {

        if (($force_fmt || '') eq 'mux') {
          # Allow the temporary files used in muxing to be overwritten.
        } else {
          exit (1) if ($verbose <= 0); # Skip silently if --quiet.
          error ("$id: exists: $file (6)")
            unless (($force_fmt || '') eq 'all');
          # Nobody uses --fmt all except for debugging; allow partial files.
          print STDERR "$progname: $id: exists: $file (6)\n";
          next;
        }
      }

      print STDERR "$progname: reading \"$ftitle\"\n" if ($verbose > 0);

      my $start_time = time();

      if (ref($url2) eq 'ARRAY') {
        my $start = time();
        my $total = scalar (@$url2);
        my $bytes = 0;
        my $bps = 0;
        my $i = 0;

        foreach my $url3 (@$url2) {
          my $append_p = ($i > 0);
          print STDERR "\n" if ($i && $progress_p && $verbose > 2);

          my ($http, $head, $body);
          print STDERR "$progname: downloading segment $i/$total\n"
            if ($verbose > 2);
          ($http, $head, $body) = get_url ($url3, undef, $file,
                                           $bwlimit, undef,
                                           $append_p, 0);

          # internal error if still 403 after retries.
          check_http_status ($id,
                             "$url segment $i/$total: $url3",
                             $http, 2);

          # When loading segmented URLs we only update the progress marker
          # when each segment is fully downloaded... but they're small,
          # that's kind of their whole point.
          #
          if ($progress_p) {
            my ($size) = ($head =~
                          m@^Content-Range: \s* bytes \s+ [-\d]+ / (\d+) @mix);
            ($size) = ($head =~ m@^Content-Length: \s* (\d+) @mix)
              unless $size;
            $bytes += $size if defined($size);  # Sometimes missing!
            my $elapsed = time() - $start;
            $bps = 8 * ($elapsed ? $bytes / $elapsed : 0);
            draw_progress ($i / $total, $bps, 0);
          }

          $i++;
        }

        draw_progress (1, $bps, 1) if ($progress_p);

      } else {
        my $force_ranges_p = ($parallel_loads <= 1);
        my ($http, $head, $body) = get_url ($url2, undef, $file,
                                            $bwlimit, undef, 0, $progress_p,
                                            $force_ranges_p);
        # internal error if still 403
        check_http_status ($id, $url2, $http, 2);
      }

      my $download_time = time() - $start_time;

      if (! -s $file) {
        print STDERR "$progname: rm \"$file\"\n" if ($verbose > 1 && -f $file);
        unlink ($file);
        error ("$file: failed: $url");
      }

      # The metadata tags seem to confuse ffmpeg.
      write_file_metadata_url ($file, $id, $url) if (!@pair);

      if ($verbose > 0) {

        # Now that we've written the file, get the real numbers from it,
        # in case the server metadata lied to us.
        my $abr = 0;
        ($w, $h, $size, $abr) = video_file_size ($file);

        $size = -1 unless $size;
        my $ss = fmt_size ($size);
        if ($w && $h) {
          $ss .= ", $w x $h";
        } elsif ($abr) {
          $ss .= ", $abr";
        }

        if ($download_time && $size > 0) {
          # Let's see how badly youtube is rate-limiting our downloads.
          my $t = sprintf("%d:%02d:%02d",
                          int($download_time/(60*60)),
                          int($download_time/(60))%60,
                          int($download_time)%60);
          $ss .= " downloaded in $t";
          my $bps = fmt_bps ($size * 8 / $download_time);
          $ss .= ", $bps";
        }

        print STDERR "$progname: wrote   \"$file\"\n";
        print STDERR "$progname:         $ss\n";
      }

#      #### I'm trying to work out how to identify the short placeholder videos
#      #### used when a video's "premier time" has not yet been reached.
#      #### The placeholder video is a countdown that is sometimes 36MB,
#      #### sometimes 501KB ??
#      ####
#      if ($verbose == 0 && $file && $file =~ m/\.mp4$/si) {
#        my $size = (stat($file))[7] || 0;
#        if (($size < (40*1024*1024)) ||
#            $title =~ m/poppy/si) {
#          print STDERR "$progname: ##### DEBUG: weirdly small file: " . 
#            int($size/(1024*1024)) . "M;\n" .
#            "$url\n\"$title\"\n\n";
#          system ("youtubedown", "--size", "-vvvv", $url);
#        }
#      }

      # If we're not muxing, this is the final file.
      delete $rm_f{$file} unless @pair;
    }

    $fmt_all_retry_kludge{$target} = 1
      if ($force_fmt && $force_fmt eq 'all');
  }

  if (@pair) {
    mux_downloaded_files ($id, $url, $title,
                          $fmts->{$pair[0]},
                          $fmts->{$pair[1]},
                          $outfile,
                          $progress_p);
  } elsif ($size_p && !@targets) {
    print STDERR "$id\tsize unknown (live stream?)\n";
  }
}


# Sometimes we get 403 and "suspicious signature" and I don't know why.
# But retrying often works.
# Also sometimes the underlying video segments are 404.
#
sub download_video_url_retry($$$$$$$$$$$$) {
  my ($url, $title, $prefix, $outfile, $size_p,
      $list_p, $list_idx, $list_count,
      $bwlimit, $progress_p, $force_fmt, $max_size) = @_;

  ($url) = canonical_url ($url);

  my $retries = 10;
  my $i = 0;
  $total_retries = 0;
  for ($i = 0; $i < $retries; $i++) {
    my $ono = $noerror;
    eval {
      $noerror = 1;
      download_video_url ($url, $title, $prefix, $outfile, $size_p,
                          $list_p, $list_idx, $list_count,
                          $bwlimit, $progress_p, $force_fmt, $max_size);
    };
    $noerror = $ono;

    last unless ($@);         # Done if no error.
   #last unless ($@ =~ m@\b403 Forbidden@); # Done if error but not 403.
    last if ($@ =~ m/$blocked_re/sio);    # These errors don't go away.

    $total_retries++;

    print STDERR "$progname: failed, retrying $url\n" if ($verbose == 2);
    last if ($verbose > 2);
    print STDERR "$progname: RETRYING $url\n\n$@\n\n" if ($verbose > 2);
    $error_whiteboard .= "retrying $url\n";
    rmf();
    sleep (1);
  }

  if ($@) {
    my $err = $@;
    $err =~ s/\s+$//s;
    $err .= " (after $i retries)" if ($i);

    if ($err && $verbose <= 0 &&
        ($err =~ m/$blocked_re/sio ||
         $err =~ m@\b403 Forbidden@s ||
         $err =~ m@\b404 Not Found@s ||
         $err =~ m@\b410 Gone@s ||
         $err =~ m@\bno video in @s ||
         $err =~ m@\bI/O error:@s ||
         $err =~ m@broken pipe@s)) {
      # With --quiet, just silently ignore private videos and 404s
      # for "youtubefeed".
      exit (1);
    }

    error ($err);
  }
}

# Construct URL for continuation of a long playlist
#
sub youtube_get_more_playlist($) {
  my ($body) = @_;
  my ($token, $track) = ($body =~
      m/"continuation"\s*:\s*"(.+?)".*?"clickTrackingParams"\s*:\s*"(.+?)"/si);
  ($track, $token) = ($body =~
      m/"clickTrackingParams"\s*:\s*"([^"]+)".*"token"\s*:\s*"(.+?)"/si)
    unless defined($track);
  return undef unless defined($track);
  return join ('&amp;',
               "/browse_ajax?ctoken=$token",
               "continuation=$token",
               "itct=$track");
}

# Returns the title and URLs of every video in the playlist.
#
sub youtube_playlist_urls($$;$) {
  my ($id, $url, $first_only_p) = @_;

  my @playlist = ();
  my $start = 0;

  my ($http, $head, $body) = get_url ($url);
  check_http_status ($id, $url, $http, 1);

  my ($title) = ($body =~ m/"og:title"\s+content="(.*?)">/si);
  ($title) = ($body =~ m@<title>\s*([^<>]+?)\s*</title>@si) unless $title;

  $title = munge_title($title);
  sanity_check_title ($title, $url, $body, 'youtube_playlist_urls');
  $title = 'Untitled Playlist' unless $title;

  if ($body =~ m/window\[.ytInitialData.\] *= *(.*?);/s) {
    $body = $1;
  } elsif ($body =~ m/var *ytInitialData *= *(.*?);/s) {
    $body = $1;
  } else {
    errorI ("playlist html unparsable: $url");
  }

  # Get the up-to-100 videos that came with the document.
  #
  $body =~ s/\n/ /g;
  $body =~ s/ \\[ux] \{ ([a-z0-9]+) \} / unihex($1) /gsexi;  # \u{XXXXXX}
  $body =~ s/ \\[ux]   ([a-z0-9]{4})   / unihex($1) /gsexi;  # \uXXXX
  $body =~ s/\\//g;
  $body =~ s/("playlistVideoRenderer")/\n$1/g;
  my $prev_id = '';
  foreach my $chunk (split (/\n/, $body)) {
    my $id = $1 if ($chunk =~ m/\{"videoId":"(.*?)"/si);
    my $t2 = $1 if ($chunk =~ m/"simpleText":"(.*?)"/si);
    $t2 = "" if ($t2 && $t2 =~ /^[\d:]*$/);  # if $t2 was index or duration
    $t2 = $1 if (!$t2 && $chunk =~ m/"title".*?"[a-z]*text":"(.*?)"\}/si);
    next unless defined($id);
    next if ($id eq $prev_id);
    $prev_id = $id;
    if ($id && $t2) {
      $t2 = munge_title (html_unquote ($t2));
      push @playlist, { title => $t2,
                        url   => 'https://www.youtube.com/watch?v=' . $id };
    }
  }

  errorI ("$id: no playlist entries") unless @playlist;

  if ($first_only_p) {
    @playlist = ( $playlist[0] );
  }


  # Scraping the HTML only gives us the first hundred videos if the
  # playlist has more than that. To get the rest requires more work.
  #
  my $more = ($first_only_p ? undef : youtube_get_more_playlist ($body));

  my $vv = $1 if ($body =~ m/"client.version","value":"(.*?)"/si);

  my $page = 2;
  while ($more) {
    $more = html_unquote ($more);
    $more = 'https:' if ($more =~ m@^//@s);
    $more = 'https://www.youtube.com' . $more if ($more =~ m@^/@s);

    print STDERR "$progname: loading playlist page $page...\n"
      if ($verbose > 1);

    errorI ("$id: no client version") unless defined($vv);
    ($http, $head, $body) = get_url_hdrs ($more,
                                          # You absolute bastards!!
                                          ["X-YouTube-Client-Name: 1",
                                           "X-YouTube-Client-Version: $vv"]);
    check_http_status ($id, $more, $http, 1);

    # Get the next up-to-100 videos.
    #
    $body =~ s/\n/ /g;
    $body =~ s/ \\[ux] \{ ([a-z0-9]+) \} / unihex($1) /gsexi;  # \u{XXXXXX}
    $body =~ s/ \\[ux]   ([a-z0-9]{4})   / unihex($1) /gsexi;  # \uXXXX
    $body =~ s/\\//g;
    $body =~ s/("playlistVideoRenderer")/\n$1/g;
    $prev_id = '';
    foreach my $chunk (split (/\n/, $body)) {
      my $id = $1 if ($chunk =~ m/\{"videoId":"(.*?)"/si);
      my $t2 = $1 if ($chunk =~ m/"simpleText":"(.*?)"/si);
      $t2 = "" if ($t2 && $t2 =~ /^[\d:]*$/);  # if $t2 was index or duration
      $t2 = $1 if (!$t2 && $chunk =~ m/"title".*?"[a-z]*text":"(.*?)"\}/si);
      next unless defined($id);
      next if ($id eq $prev_id);
      $prev_id = $id;
      if ($id && $t2) {
        $t2 = munge_title (html_unquote ($t2));
        push @playlist, { title => $t2,
                          url   => 'https://www.youtube.com/watch?v=' . $id };
      }
    }

    $more = youtube_get_more_playlist ($body);
    $page++;
  }

  # Prefix each video's title with the playlist's title and its index.
  #
  my $i = 0;
  my $count = @playlist;
  foreach my $P (@playlist) {
    $i++;
    my $t2 = $P->{'title'};
    $t2 = munge_title (html_unquote ($t2));
    sanity_check_title ($t2, $url, $body, 'youtube_playlist_urls 2');
    my $ii = ($count > 999 ? sprintf("%04d", $i) :
              $count >  99 ? sprintf("%03d", $i) :
                             sprintf("%02d", $i));
    $t2 = "$title: $ii: $t2";
    $P->{'title'} = $t2;
  }

  return ($title, @playlist);
}


sub download_youtube_playlist($$$$$$$$$$) {
  my ($id, $url, $title, $prefix, $size_p, $list_p,
      $bwlimit, $progress_p, $force_fmt, $max_size) = @_;

  # With "--size", only get the size of the first video.
  # With "--size --size", get them all.

  my ($title2, @playlist) = youtube_playlist_urls($id, $url, ($size_p eq 1));
  $title = $title2 unless $title;

  print STDERR "$progname: playlist \"$title\" (" . scalar (@playlist) .
                 " entries)\n"
    if ($verbose > 1);

  my $list_count = scalar @playlist;
  my $list_idx = 0;
  foreach my $P (@playlist) {
    my $t2 = $P->{'title'};
    my $u2 = $P->{'url'};
    my $ono = $noerror;
    eval {
      $noerror = 1;
      utf8::encode ($t2) if defined($t2);
      download_video_url_retry ($u2, $t2, $prefix, undef, $size_p, $list_p,
                                $list_idx, $list_count,
                                $bwlimit, $progress_p, $force_fmt,
                                $max_size);
      $noerror = $ono;
    };
    print STDERR "$progname: $@" if $@;
    last if ($size_p eq 1);
    $list_idx++;
  }
}


sub parse_size($$) {
  my ($arg, $s) = @_;
  usage ("unparsable size: $arg") unless defined($s);
  if    ($s =~ m/^8K$/si)        { $s = '7680x4320'; }
  elsif ($s =~ m/^UHD$/si)       { $s = '7680x4320'; }
  elsif ($s =~ m/^4320[pi]$/si)  { $s = '7680x4320'; }
  elsif ($s =~ m/^5K$/si)        { $s = '5120x2880'; }
  elsif ($s =~ m/^2880[pi]$/si)  { $s = '5120x2880'; }
  elsif ($s =~ m/^4K$/si)        { $s = '4096x2160'; }
  elsif ($s =~ m/^QHD$/si)       { $s = '2560x1440'; }
  elsif ($s =~ m/^1440[pi]?$/si) { $s = '2560x1440'; }
  elsif ($s =~ m/^2K$/si)        { $s = '2048x1080'; }
  elsif ($s =~ m/^1080[pi]?$/si) { $s = '1920x1080'; }
  elsif ($s =~ m/^720[pi]?$/si)  { $s = '1280x720';  }
  elsif ($s =~ m/^PAL$/si)       { $s =  '720x576';  }
  elsif ($s =~ m/^576[pi]?$/si)  { $s =  '720x576';  }
  elsif ($s =~ m/^DV$/si)        { $s =  '720x480';  }
  elsif ($s =~ m/^480[pi]$/si)   { $s =  '720x480';  }
  elsif ($s =~ m/^SD$/si)        { $s =  '640x480';  }
  elsif ($s =~ m/^NTSC$/si)      { $s =  '640x480';  }
  return $s if ($s =~ m/^(\d+)x(\d+)$/s);
  usage ("unparsable size: $arg $s");
}

sub usage() {
  print STDERR "usage: $progname" .
                 " [--verbose] [--quiet] [--progress] [--size]\n" .
           "\t\t   [--title txt] [--prefix txt] [--suffix] [--out file]\n" .
           "\t\t   [--fmt N] [--no-mux] [--bwlimit N [kb | KB | mb | MB]]\n" .
           "\t\t   [--max-size WxH] [--webm] [--webm-transcode]\n" .
           "\t\t   [--parallel-loads N]\n" .
           "\t\t   youtube-or-vimeo-urls ...\n";
  exit 1;
}

sub main() {

  binmode (STDOUT, ':utf8');   # video titles in messages
  binmode (STDERR, ':utf8');

  # historical suckage: the environment variable name is lower case.
  $http_proxy = ($ENV{http_proxy}  || $ENV{HTTP_PROXY} ||
                 $ENV{https_proxy} || $ENV{HTTPS_PROXY});
  delete $ENV{http_proxy};
  delete $ENV{HTTP_PROXY};
  delete $ENV{https_proxy};
  delete $ENV{HTTPS_PROXY};

  if ($http_proxy && $http_proxy !~ m/^http/si) {
    # historical suckage: allow "host:port" as well as "http://host:port".
    $http_proxy = "http://$http_proxy";
  }

  my @urls = ();
  my $title = undef;
  my $prefix = undef;
  my $out = undef;
  my $size_p = 0;
  my $list_p = 0;
  my $progress_p = 0;
  my $fmt = undef;
  my $expect = undef;
  my $guessp = 0;
  my $muxp = 1;
  my $bwlimit = undef;
  my $max_size = undef;

  while ($#ARGV >= 0) {
    $_ = shift @ARGV;
    if (m/^--?verbose$/)     { $verbose++; }
    elsif (m/^-v+$/)         { $verbose += length($_)-1; }
    elsif (m/^--?q(uiet)?$/) { $verbose--; }
    elsif (m/^--?progress$/) { $progress_p++; }
    elsif (m/^--?no-progress$/) { $progress_p = 0; }
    elsif (m/^--?suffix$/)   { $append_suffix_p = 1; }
    elsif (m/^--?no-suffix$/)   { $append_suffix_p = 0; }
    elsif (m/^--?prefix$/)   { $expect = $_; $prefix = shift @ARGV; }
    elsif (m/^--?title$/)    { $expect = $_; $title = shift @ARGV; }
    elsif (m/^--?out$/)      { $expect = $_; $out = shift @ARGV; }
    elsif (m/^--?size$/)     { $expect = $_; $size_p++; }
    elsif (m/^--?ping$/)     { $expect = $_; $size_p = 'ping'; }
    elsif (m/^--?list$/)     { $expect = $_; $list_p++; }
    elsif (m/^--?fmt$/)      { $expect = $_; $fmt = shift @ARGV; }
    elsif (m/^--?mux$/)      { $expect = $_; $muxp = 1; }
    elsif (m/^--?no-?mux$/)  { $expect = $_; $muxp = 0; }
    elsif (m/^--?webm$/)     { $expect = $_; $webm_p = 1; }
    elsif (m/^--?no-?webm$/) { $expect = $_; $webm_p = 0; }
    elsif (m/^--?webm-trans(code)?$/)     { $webm_p = 1;
                                            $webm_transcode_p = 1; }
    elsif (m/^--?no-?webm-trans(code)?$/) { $webm_transcode_p = 0; }
    elsif (m/^--?max-size$/) { $max_size = parse_size ($_, shift @ARGV); }
    elsif (m/^--?guess$/)    { $guessp++; }
    elsif (m/^--?para(l+el+(-loads?)?)?$/) { $parallel_loads = 0+shift @ARGV; }
    elsif (m/^--?bwlimit$/) {
      #
      # Many variant spellings are allowed:
      #
      # bits:  k, kb, kbps, kps, kb/s, k/s;
      # bytes: K, Kb, Kbps, Kps, Kb/s, K/s,
      #           KB, KBps, KBPS, KPS, KB/s, KB/S, K/S.
      #
      my $bit_suf  = '(b|bps|ps|b/s|/s)?$';
      my $byte_suf = '(b|bps|ps|b/s|/s|B|Bps|BPS|PS|B/s|B/S|/S)?$';

      $bwlimit = shift @ARGV;
      if      ($bwlimit =~ s@ \s*  k $bit_suf  @@sx) {  # k bits
        $bwlimit *= 1024;
      } elsif ($bwlimit =~ s@ \s*  K $byte_suf @@sx) {  # K bytes
        $bwlimit *= 1024 * 8;
      } elsif ($bwlimit =~ s@ \s*  m $bit_suf  @@sx) {  # m bits
        $bwlimit *= 1024 * 1024;
      } elsif ($bwlimit =~ s@ \s*  M $byte_suf @@sx) {  # M bytes
        $bwlimit *= 1024 * 1024 * 8;
      } elsif ($bwlimit =~ s@ \s*  g $bit_suf  @@sx) {  # g bits
        $bwlimit *= 1024 * 1024 * 1024;
      } elsif ($bwlimit =~ s@ \s*  G $byte_suf @@sx) {  # G bytes
        $bwlimit *= 1024 * 1024 * 1024 * 8;
      } elsif ($bwlimit =~ s@ \s*    $bit_suf  @@sx) {  # bits
        $bwlimit += 0;
      } elsif ($bwlimit =~ s@ \s*    $byte_suf @@sx) {  # Bytes
        $bwlimit /= 8;
      } elsif ($bwlimit =~ m@^ \d+ ( \.\d+ )? $ @sx) {  # no units: k bits
        $bwlimit *= 1024;
      } else {
        error ("unparsable units: $bwlimit");
      }
    } elsif (m/^-./)           { usage; }
    else {
      s@^//@https://@s;
      error ("not a Youtube, Vimeo, Instagram, Tumblr," .
             " or Twitter URL: $_")
        unless (m@^(https?://)?
                   ([a-z]+\.)?
                   ( youtube(-nocookie)?\.com/ |
                     youtu\.be/ |
                     vimeo\.com/ |
                     google\.com/ .* service=youtube |
                     youtube\.googleapis\.com
                     tumblr\.com/ |
                     instagram\.com/ |
                     twitter\.com/ |
                   )@six);
      $fmt = 'mux' if ($muxp && !defined($fmt));
      usage if (defined($fmt) && $fmt !~ m/^\d+|all|mux$/s);
      my @P = ($title, $fmt, $out, $_);
      push @urls, \@P;
      $title = undef;
      $out = undef;
      $expect = undef;
    }
  }

  error ("$expect applies to the following URLs, so it must come first")
    if ($expect);

  if ($guessp) {
    guess_cipher (undef, $guessp - 1);
    exit (0);
  }

  # 28-Jan-2022: Does this help? I dunno, maybe? Getting a lot of
  # "30 seconds with no data" timeouts with odd formats when doing
  # "--size --fmt all".
  $parallel_loads = 0 if $size_p;

  usage unless ($#urls >= 0);
  foreach (@urls) {
    my ($title, $fmt, $out, $url) = @$_;
    download_video_url_retry ($url, $title, $prefix, $out, $size_p,
                              $list_p, 0, 0, 
                              $bwlimit, $progress_p, $fmt, $max_size);
  }
  exit 0;
}

main() unless caller();
1;