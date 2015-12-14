#!/usr/bin/perl -w
# Copyright © 2007-2015 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
#
# Given a YouTube, Vimeo or Tumblr URL, downloads the corresponding MP4 file.
# The name of the file will be derived from the title of the video.
#
#  --title "STRING"  Use this as the title instead.
#  --prefix "STRING" Prepend the title with this.
#  --suffix          Append the video ID to each written file name.
#  --progress        Show a textual progress bar for downloads.
#
#  --size            Instead of downloading it all, print video dimensions.
#		     This requires "ffmpeg".
#
#  --list            List the underlying URLs of a playlist.
#  --list --list     List IDs and titles of a playlist.
#  --size --size     List the sizes of each video of a playlist.
#
#  --no-mux          Only download pre-muxed videos, instead of sometimes
#                    downloading separate audio and video files, then combining
#                    them afterward with "ffmpeg".  If you specify this option,
#                    you probably can't download anything higher resolution
#                    than 720p.
#
# Note: if you have ffmpeg < 2.2, upgrade to something less flaky.
#
# For playlists, it will download each video to its own file.
#
# You can also use this as a bookmarklet: put it somewhere on your web server
# as a .cgi, then bookmark this URL:
#
#   javascript:location='http://YOUR_SITE/youtubedown.cgi?url='+location
#
# or, the same thing but using a small popup window,
#
#   javascript:window.open('http://YOUR_SITE/youtubedown.cgi?url='+location.toString().replace(/%26/g,'%2526').replace(/%23/g,'%2523'),'youtubedown','width=400,height=50,top=0,left='+((screen.width-400)/2))
#
#
# When you click on that bookmarklet in your toolbar, it will give you
# a link on which you can do "Save Link As..." and be offered a sensible
# file name by default.
#
# Make sure you host that script on your *local machine*, because the entire
# video content will be proxied through the server hosting the CGI, and you
# don't want to effectively download everything twice.
#
# Created: 25-Apr-2007.

require 5;
use diagnostics;
use strict;
use IO::Socket;
use IO::Socket::SSL;
use IPC::Open3;
use HTML::Entities;

my $progname0 = $0;
my $progname = $0; $progname =~ s@.*/@@g;
my ($version) = ('$Revision: 1.655 $' =~ m/\s(\d[.\d]+)\s/s);

# Without this, [:alnum:] doesn't work on non-ASCII.
use locale;
use POSIX qw(locale_h strftime);
setlocale(LC_ALL, "en_US");

my $verbose = 1;
my $append_suffix_p = 0;

my $http_proxy = undef;

$ENV{PATH} = "/opt/local/bin:$ENV{PATH}";   # for macports ffmpeg

my @video_extensions = ("mp4", "flv", "webm");


my $html_head =
  ("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\"\n" .
   "	  \"http://www.w3.org/TR/html4/loose.dtd\">\n" .
   "<HTML>\n" .
   " <HEAD>\n" .
   "  <TITLE></TITLE>\n" .
   " <STYLE TYPE=\"text/css\">\n" .
   "  body { font-family: Arial,Helvetica,sans-serif; font-size: 12pt;\n" .
   "         color: #000; background: #FF0; white-space: nowrap; }\n" .
   "  a { font-weight: bold; }\n" .
   "  .err { font-weight: bold; color: #F00; white-space: normal; }\n" .
   " </STYLE>\n" .
   " </HEAD>\n" .
   " <BODY>\n");
my $html_tail = " </BODY>\n</HTML>\n";
     

# Anything placed on this list gets unconditionally deleted when this
# script exits, even if abnormally.  This is how CGI-mode cleans up
# after itself.
#
my @rm_r = ();
END { unlink @rm_r if (@rm_r); }


my $noerror = 0;

sub error($) {
  my ($err) = @_;

  utf8::decode ($err);  # Pack multi-byte UTF-8 back into wide chars.

  if (defined ($ENV{HTTP_HOST})) {
    $err =~ s/&/&amp;/gs;
    $err =~ s/</&lt;/gs;
    $err =~ s/>/&gt;/gs;

    # $error_whiteboard kludge
    $err =~ s/^\t//gm;
    $err =~ s@\n\n(.*)\n\n@<PRE STYLE="font-size:9pt">$1</PRE>@gs;
    # $err =~ s/\n/<BR>/gs;

    $err = $html_head . '<P><SPAN CLASS="err">ERROR:</SPAN> ' . $err .
           $html_tail;
    $err =~ s@(<TITLE>)[^<>]*@$1$progname: Error@gsi;

    print STDOUT ("Content-Type: text/html\n" .
                  "Status: 500\n" .
                  "\n" .
                  $err);
    die "$err\n" if ($verbose > 2);  # For debugging CGI.
    exit 1;
  } elsif ($noerror) {
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
              "\n\thttp://www.jwz.org/hacks/#youtubedown" .
              "\n");
my $error_whiteboard = '';	# for signature diagnostics

sub errorI($) {
  my ($err) = @_;
  if ($error_whiteboard) {
    $error_whiteboard =~ s/^/\t/gm;
    $err .= "\n\n" . $error_whiteboard;
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
  return ($size > 1024*1024 ? sprintf ("%.0f MB", $size/(1024*1024)) :
          $size > 1024      ? sprintf ("%.0f KB", $size/1024) :
          "$size bytes");
}

sub fmt_bps($) {
  my ($bps) = @_;
  return ($bps > 1024*1024 ? sprintf ("%.1f Mbps", $bps/(1024*1024)) :
          $bps > 1024      ? sprintf ("%.1f Kbps", $bps/1024) :
          "$bps bps");
}


my $progress_ticks = 0;
my $progress_time = 0;

sub draw_progress($;$) {
  my ($ratio, $cgi_p) = @_;

  my $cols = ($cgi_p ? 100 : 72);
  my $ticks = int($cols * $ratio);

  my $now = time();
  my $eof = ($ratio == -1);
  $ratio = 1 if $eof;

  return if ($progress_time == $now && !$eof);

  if ($cgi_p) {			# See comment on "X-Heartbeat" in do_cgi().
    while ($ticks > $progress_ticks) {
      print STDOUT ".";
      $progress_ticks++;
    }
    $progress_time = $now;
    $progress_ticks = 0 if ($eof);
    return;
  }

  if ($ticks > $progress_ticks) {
    my $pct = sprintf("%3d%%", 100 * $ratio);
    $pct =~ s/^  /. /s;
    print STDERR "\b" x length($pct)			# erase previous pct
      if ($progress_ticks > 0);
    while ($ticks > $progress_ticks) {
      print STDERR ".";
      $progress_ticks++;
    }
    print STDERR $pct;
  }
  print STDERR "\r" . (' ' x ($cols + 4)) . "\r" if ($eof);	# erase line
  $progress_time = $now;
  $progress_ticks = 0 if ($eof);
}



# Loads the given URL, returns: $http, $head, $body.
#
sub get_url_1($;$$$$) {
  my ($url, $referer, $to_file, $max_bytes, $progress_p) = @_;
  
  error ("not an HTTP URL, try rtmpdump: $url") if ($url =~ m@^rtmp@i);
  error ("not an HTTP URL: $url") unless ($url =~ m@^(https?|feed)://@i);

  my ($proto, undef, $host, $path) = split(m@/@, $url, 4);
  $path = "" unless defined ($path);
  $path = "/$path";

  my $port = ($host =~ s@:([^:/]*)$@@gs ? $1 : undef);

  my $ohost = $host;
  if ($http_proxy) {
    ($proto, undef, $host, undef) = split(m@/@, $http_proxy, 4);
    $path = $url;
  }

  my $S;
  if ($proto eq 'http:') {
    $port = 80 unless $port;
    $S = IO::Socket::INET->new (PeerAddr => $host,
                                PeerPort => $port,
                                Proto    => 'tcp',
                                Type     => SOCK_STREAM,
                                );
  } else {
    $port = 443 unless $port;
    $S = IO::Socket::SSL->new  (PeerAddr => $host,
                                PeerPort => $port,
                                Proto    => 'tcp',
                                Type     => SOCK_STREAM,
                                # Ignore certificate errors
                                verify_hostname => 0,
                                SSL_verify_mode => 0
                                );
  }
  error ("connect: $host:$port: $!") unless $S;

  $S->autoflush(1);

  my $user_agent = "$progname/$version";

  my $hdrs = ("GET " . $path . " HTTP/1.0\r\n" .
              "Host: $ohost\r\n" .
              "User-Agent: $user_agent\r\n");

  my $extra_headers = '';
  $extra_headers .= "\nReferer: $referer" if ($referer);

  # If we're only reading the first N bytes, don't ask for more.
  $extra_headers .= "Range: bytes=0-" . ($max_bytes-1) . "\r\n"
    if ($max_bytes);

  if ($extra_headers) {
    $extra_headers =~ s/\r\n/\n/gs;
    $extra_headers =~ s/\r/\n/gs;
    foreach (split (/\n/, $extra_headers)) {
      $hdrs .= "$_\r\n" if $_;
    }
  }

  $hdrs .= "\r\n";

  if ($verbose > 3) {
    foreach (split('\r?\n', $hdrs)) {
      print STDERR "  ==> $_\n";
    }
  }
  print $S $hdrs;

  my $bufsiz = 10240;
  my $buf = '';

  # Read network buffers until we have the HTTP response line.
  my $http = '';
  while (! $http) {
    if ($buf =~ m/^(.*?)\n(.*)$/s) {
      ($http, $buf) = ($1, $2);
      last;
    }
    my $buf2 = '';
    my $size = sysread ($S, $buf2, $bufsiz);
    print STDERR "  read A $size\n" if ($verbose > 5);
    last if (!defined($size) || $size <= 0);
    $buf .= $buf2;
  }

  $_ = $http;
  s/[\r\n]+$//s;
  print STDERR "  <== $_\n" if ($verbose > 3);

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
    my $size = sysread ($S, $buf2, $bufsiz);
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

  # Note that if we requested a byte range, this is the length of the range,
  # not the length of the full document.
  my ($cl) = ($head =~ m@^Content-Length: \s* (\d+) @mix);
  $cl = $max_bytes if ($max_bytes && (!$cl || $max_bytes < $cl));

  $progress_p = 0 if (($progress_p || '') ne 'cgi' && ($cl || 0) <= 0);

  my $out;

  if ($to_file) {
    # No, don't do this.
    # utf8::encode($to_file);   # Unpack wide chars into multi-byte UTF-8.

    # Must be 2-arg open for ">-" when $outfile is '-'.
    open ($out, ">$to_file") || error ("$to_file: $!");
    binmode ($out);
  }

  # If we're proxying a download, also copy the document's headers.
  #
  if ($to_file && $to_file eq '-') {

    # Maybe if we nuke the Content-Type, that will stop Safari from
    # opening the file by default.  Answer: nope.
    #  $head =~ s@^(Content-Type:)[^\r\n]+@$1 application/octet-stream@gmi;
    # Ok, maybe if we mark it as an attachment?  Answer: still nope.
    #  $head = "Content-Disposition: attachment\r\n" . $head;

    print $out $head . "\n\n";
  }

  my $bytes = 0;
  my $body = '';

  my $cgi_p = ($progress_p && $progress_p eq 'cgi');

  while (1) {
    if ($buf eq '') {
      my $size = sysread ($S, $buf, $bufsiz);
      print STDERR "  read C $size ($bytes)\n" if ($verbose > 5);
      last if (!defined($size) || $size <= 0);
    }

    if ($to_file) {
      print $out $buf;
    } else {
      $body .= $buf;
    }

    $bytes += length($buf);
    $buf = '';

    draw_progress ($bytes / $cl, $cgi_p) if ($progress_p);

    # If we do a read while at EOF, sometimes Youtube hangs for ~30 seconds
    # before sending back the EOF, so just stop reading as soon as we have
    # reached the Content-Length or $max_bytes.
    #
    last if ($cl && $bytes >= $cl);
  }
  draw_progress (-1, $cgi_p) if ($progress_p);

  if ($to_file) {
    close $out || error ("$to_file: $!");
  }

  if ($verbose > 3) {
    if ($to_file) {
      print STDERR "  <== [ body ]: $bytes bytes to file \"$to_file\"\n";
    } else {
      print STDERR "  <== [ body ]: $bytes bytes\n";
      if ($verbose > 4 &&
          $head =~ m@^Content-Type: *(text/|application/(json|x-www-))@mi) {
        foreach (split(/\n/, $body)) {
          s/\r$//gs;
          print STDERR "  <== $_\n";
        }
      }
    }
  }

  close $S;

  if (!$http) {
    error ("null response: $url");
  }

  # Check to see if a network failure truncated the file.
  # Maybe we should delete the file too?
  #
  if ($to_file && $cl && $bytes < $cl-1) {
    my $pct = int (100 * $bytes / $cl);
    $pct = sprintf ("%.2f", 100 * $bytes / $cl) if ($pct == 100);
    unlink ($to_file);   # No way to resume partials, so just delete it.
    error ("got only $pct% ($bytes instead of $cl) of \"$to_file\"");
  }

  return ($http, $head, $body);
}


# Loads the given URL, processes redirects.
# Returns: $http, $head, $body, $final_redirected_url.
#
sub get_url($;$$$$) {
  my ($url, $referer, $to_file, $max_bytes, $progress_p) = @_;

  print STDERR "$progname: GET $url\n" if ($verbose > 2);

  my $orig_url = $url;
  my $redirect_count = 0;
  my $max_redirects  = 20;

  do {
    my ($http, $head, $body) = 
      get_url_1 ($url, $referer, $to_file, $max_bytes, $progress_p);

    $http =~ s/[\r\n]+$//s;

    if ( $http =~ m@^HTTP/[0-9.]+ 30[123]@ ) {
      $_ = $head;

      my ( $location ) = m@^location:[ \t]*(.*)$@im;
      if ( $location ) {
        $location =~ s/[\r\n]$//;

        print STDERR "$progname: redirect from $url to $location\n"
          if ($verbose > 3);

        $referer = $url;
        $url = $location;

        if ($url =~ m@^/@) {
          $referer =~ m@^(https?://[^/]+)@i;
          $url = $1 . $url;
        } elsif (! ($url =~ m@^[a-z]+:@i)) {
          $_ = $referer;
          s@[^/]+$@@g if m@^https?://[^/]+/@i;
          $_ .= "/" if m@^https?://[^/]+$@i;
          $url = $_ . $url;
        }

      } else {
        error ("no Location with \"$http\"");
      }

      error ("too many redirects ($max_redirects) from $orig_url")
        if ($redirect_count++ > $max_redirects);

    } else {
      return ($http, $head, $body, $url);
    }
  } while (1);
}


sub check_http_status($$$$) {
  my ($id, $url, $http, $err_p) = @_;
  return 1 if ($http =~ m@^HTTP/[0-9.]+ 20\d@si);
  errorI ("$id: $http: $url") if ($err_p > 1 && $verbose > 0);
  error  ("$id: $http: $url") if ($err_p);
  return 0;
}


# Runs ffmpeg to determine dimensions of the given video file.
# (We only do this in verbose mode, or with --size.)
#
sub video_file_size($) {
  my ($file) = @_;

  # Sometimes ffmpeg gets stuck in a loop.  
  # Don't let it run for more than N CPU-seconds.
  my $limit = "ulimit -t 10";

  my $size = (stat($file))[7];

  my @cmd = ("ffmpeg",
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
    if ($result =~ m/^\s*Stream #.* Video:.* (\d+)x(\d+),? /m);
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
# Unfortunately, in CGI-mode, the file is actually being downloaded by
# the browser itself, so the metadata URL that gets written is the
# youtubedown.cgi URL.  The original URL info is still buried in there,
# but it's messier.
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
          print $in $s;
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
            print STDERR "$progname: $id: $plutil: core dumped!"
              if ($dumped_core);
            print STDERR "$progname: $id: $plutil: signal $signal_num!"
              if ($signal_num);
            print STDERR "$progname: $id: $plutil: exited with $exit_value!"
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
    foreach ($date_plist, $url_plist, $quarantine) {
      s/(.)/{ sprintf("%02X ", ord($1)); }/gsex;
    }

    # Now run xattr for each attribute to dump it into the file.
    #
    error ("$file does not exist") unless (-f $file);
    foreach ([$url_plist,  'com.apple.metadata:kMDItemWhereFroms'],
             [$date_plist, 'com.apple.metadata:kMDItemDownloadedDate'],
             [$quarantine, 'com.apple.quarantine']) {
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

        if ($verbose) {
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
sub video_url_size($$;$) {
  my ($id, $url, $ct) = @_;

  my $tmp = $ENV{TMPDIR} || "/tmp";
  my $ext = content_type_ext ($ct || '');
  my $file = sprintf("$tmp/$progname-%08x.$ext", rand(0xFFFFFFFF));
  unlink $file;
  push @rm_r, $file;

  # Need a lot of data to get size from 1080p.
  #
  # This used to be 320 KB, but I see 640x360 140 MB videos where we can't
  # get the size without 680 KB.
  #
  # And now I see a 624 x 352, 180 MB, 50 minute video that gets
  # "error reading header: -541478725" unless we read 910 KB.
  #
  my $bytes = 910 * 1024;

  my ($http, $head, $body) = get_url ($url, undef, $file, $bytes);
  check_http_status ($id, $url, $http, 2);  # internal error if still 403

     ($ct)   = ($head =~ m@^Content-Type:   \s* ( [^\s;]+ ) @mix);
  my ($size) = ($head =~ m@^Content-Range:  \s* bytes \s+ [-\d]+ / (\d+) @mix);
     ($size) = ($head =~ m@^Content-Length: \s* (\d+) @mix)
       unless $size;

  errorI ("$id: expected audio or video, got \"$ct\" in $url")
    if ($ct =~ m/text/i);

  $size = -1 unless defined($size); # WTF?

  my ($w, $h, undef, $abr) = video_file_size ($file);
  unlink $file;

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
#         http://s.ytimg.com/yts/jsbin/html5player-VERSION.js
#   or    http://s.ytimg.com/yts/jsbin/player-VERSION/base.js
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
# which is a timestamp or other ID code corresponding to this algorithm.
# Requesting get_video_info with that number will return URLs using the
# corresponding cipher algorithm. Except sometimes those old 'sts' values
# stop working!  See below.
#
my %ciphers = (
  'vflNzKG7n' => '135957536242 s3 r s2 r s1 r w67',		  # 30 Jan 2013
  'vfllMCQWM' => '136089118952 s2 w46 r w27 s2 w43 s2 r',	  # 14 Feb 2013
  'vflJv8FA8' => '136304655662 s1 w51 w52 r',			  # 11 Mar 2013
  'vflR_cX32' => '1580 s2 w64 s3',				  # 11 Apr 2013
  'vflveGye9' => '1582 w21 w3 s1 r w44 w36 r w41 s1',		  # 02 May 2013
  'vflj7Fxxt' => '1583 r s3 w3 r w17 r w41 r s2',		  # 14 May 2013
  'vfltM3odl' => '1584 w60 s1 w49 r s1 w7 r s2 r',		  # 23 May 2013
  'vflDG7-a-' => '1586 w52 r s3 w21 r s3 r',			  # 06 Jun 2013
  'vfl39KBj1' => '1586 w52 r s3 w21 r s3 r',			  # 12 Jun 2013
  'vflmOfVEX' => '1586 w52 r s3 w21 r s3 r',			  # 21 Jun 2013
  'vflJwJuHJ' => '1588 r s3 w19 r s2',				  # 25 Jun 2013
  'vfl_ymO4Z' => '1588 r s3 w19 r s2',				  # 26 Jun 2013
  'vfl26ng3K' => '15888 r s2 r',				  # 08 Jul 2013
  'vflcaqGO8' => '15897 w24 w53 s2 w31 w4',			  # 11 Jul 2013
  'vflQw-fB4' => '15902 s2 r s3 w9 s3 w43 s3 r w23',		  # 16 Jul 2013
  'vflSAFCP9' => '15904 r s2 w17 w61 r s1 w7 s1',		  # 18 Jul 2013
  'vflART1Nf' => '15908 s3 r w63 s2 r s1',			  # 22 Jul 2013
  'vflLC8JvQ' => '15910 w34 w29 w9 r w39 w24',			  # 25 Jul 2013
  'vflm_D8eE' => '15916 s2 r w39 w55 w49 s3 w56 w2',		  # 30 Jul 2013
  'vflTWC9KW' => '15917 r s2 w65 r',				  # 31 Jul 2013
  'vflRFcHMl' => '15921 s3 w24 r',				  # 04 Aug 2013
  'vflM2EmfJ' => '15920 w10 r s1 w45 s2 r s3 w50 r',		  # 06 Aug 2013
  'vflz8giW0' => '15919 s2 w18 s3',				  # 07 Aug 2013
  'vfl_wGgYV' => '15923 w60 s1 r s1 w9 s3 r s3 r',		  # 08 Aug 2013
  'vfl1HXdPb' => '15926 w52 r w18 r s1 w44 w51 r s1',		  # 12 Aug 2013
  'vflkn6DAl' => '15932 w39 s2 w57 s2 w23 w35 s2',		  # 15 Aug 2013
  'vfl2LOvBh' => '15933 w34 w19 r s1 r s3 w24 r',		  # 16 Aug 2013
  'vfl-bxy_m' => '15936 w48 s3 w37 s2',				  # 20 Aug 2013
  'vflZK4ZYR' => '15938 w19 w68 s1',				  # 21 Aug 2013
  'vflh9ybst' => '15936 w48 s3 w37 s2',				  # 21 Aug 2013
  'vflapUV9V' => '15943 s2 w53 r w59 r s2 w41 s3',		  # 27 Aug 2013
  'vflg0g8PQ' => '15944 w36 s3 r s2',				  # 28 Aug 2013
  'vflHOr_nV' => '15947 w58 r w50 s1 r s1 r w11 s3',		  # 30 Aug 2013
  'vfluy6kdb' => '15953 r w12 w32 r w34 s3 w35 w42 s2',		  # 05 Sep 2013
  'vflkuzxcs' => '15958 w22 w43 s3 r s1 w43',			  # 10 Sep 2013
  'vflGNjMhJ' => '15956 w43 w2 w54 r w8 s1',			  # 12 Sep 2013
  'vfldJ8xgI' => '15964 w11 r w29 s1 r s3',			  # 17 Sep 2013
  'vfl79wBKW' => '15966 s3 r s1 r s3 r s3 w59 s2',		  # 19 Sep 2013
  'vflg3FZfr' => '15969 r s3 w66 w10 w43 s2',			  # 24 Sep 2013
  'vflUKrNpT' => '15973 r s2 r w63 r',				  # 25 Sep 2013
  'vfldWnjUz' => '15976 r s1 w68',				  # 30 Sep 2013
  'vflP7iCEe' => '15981 w7 w37 r s1',				  # 03 Oct 2013
  'vflzVne63' => '15982 w59 s2 r',				  # 07 Oct 2013
  'vflO-N-9M' => '15986 w9 s1 w67 r s3',			  # 09 Oct 2013
  'vflZ4JlpT' => '15988 s3 r s1 r w28 s1',			  # 11 Oct 2013
  'vflDgXSDS' => '15988 s3 r s1 r w28 s1',			  # 15 Oct 2013
  'vflW444Sr' => '15995 r w9 r s1 w51 w27 r s1 r',		  # 17 Oct 2013
  'vflK7RoTQ' => '15996 w44 r w36 r w45',			  # 21 Oct 2013
  'vflKOCFq2' => '16 s1 r w41 r w41 s1 w15',			  # 23 Oct 2013
  'vflcLL31E' => '16 s1 r w41 r w41 s1 w15',			  # 28 Oct 2013
  'vflz9bT3N' => '16 s1 r w41 r w41 s1 w15',			  # 31 Oct 2013
  'vfliZsE79' => '16010 r s3 w49 s3 r w58 s2 r s2',		  # 05 Nov 2013
  'vfljOFtAt' => '16014 r s3 r s1 r w69 r',			  # 07 Nov 2013
  'vflqSl9GX' => '16023 w32 r s2 w65 w26 w45 w24 w40 s2',	  # 14 Nov 2013
  'vflFrKymJ' => '16023 w32 r s2 w65 w26 w45 w24 w40 s2',	  # 15 Nov 2013
  'vflKz4WoM' => '16027 w50 w17 r w7 w65',			  # 19 Nov 2013
  'vflhdWW8S' => '16030 s2 w55 w10 s3 w57 r w25 w41',		  # 21 Nov 2013
  'vfl66X2C5' => '16031 r s2 w34 s2 w39',			  # 26 Nov 2013
  'vflCXG8Sm' => '16031 r s2 w34 s2 w39',			  # 02 Dec 2013
  'vfl_3Uag6' => '16034 w3 w7 r s2 w27 s2 w42 r',		  # 04 Dec 2013
  'vflQdXVwM' => '16047 s1 r w66 s2 r w12',			  # 10 Dec 2013
  'vflCtc3aO' => '16051 s2 r w11 r s3 w28',			  # 12 Dec 2013
  'vflCt6YZX' => '16051 s2 r w11 r s3 w28',			  # 17 Dec 2013
  'vflG49soT' => '16057 w32 r s3 r s1 r w19 w24 s3',		  # 18 Dec 2013
  'vfl4cHApe' => '16059 w25 s1 r s1 w27 w21 s1 w39',		  # 06 Jan 2014
  'vflwMrwdI' => '16058 w3 r w39 r w51 s1 w36 w14',		  # 06 Jan 2014
  'vfl4AMHqP' => '16060 r s1 w1 r w43 r s1 r',			  # 09 Jan 2014
  'vfln8xPyM' => '16080 w36 w14 s1 r s1 w54',			  # 10 Jan 2014
  'vflVSLmnY' => '16081 s3 w56 w10 r s2 r w28 w35',		  # 13 Jan 2014
  'vflkLvpg7' => '16084 w4 s3 w53 s2',				  # 15 Jan 2014
  'vflbxes4n' => '16084 w4 s3 w53 s2',				  # 15 Jan 2014
  'vflmXMtFI' => '16092 w57 s3 w62 w41 s3 r w60 r',		  # 23 Jan 2014
  'vflYDqEW1' => '16094 w24 s1 r s2 w31 w4 w11 r',		  # 24 Jan 2014
  'vflapGX6Q' => '16093 s3 w2 w59 s2 w68 r s3 r s1',		  # 28 Jan 2014
  'vflLCYwkM' => '16093 s3 w2 w59 s2 w68 r s3 r s1',		  # 29 Jan 2014
  'vflcY_8N0' => '16100 s2 w36 s1 r w18 r w19 r',		  # 30 Jan 2014
  'vfl9qWoOL' => '16104 w68 w64 w28 r',				  # 03 Feb 2014
  'vfle-mVwz' => '16103 s3 w7 r s3 r w14 w59 s3 r',		  # 04 Feb 2014
  'vfltdb6U3' => '16106 w61 w5 r s2 w69 s2 r',			  # 05 Feb 2014
  'vflLjFx3B' => '16107 w40 w62 r s2 w21 s3 r w7 s3',		  # 10 Feb 2014
  'vfliqjKfF' => '16107 w40 w62 r s2 w21 s3 r w7 s3',		  # 13 Feb 2014
  'ima-vflxBu-5R' => '16107 w40 w62 r s2 w21 s3 r w7 s3',	  # 13 Feb 2014
  'ima-vflrGwWV9' => '16119 w36 w45 r s2 r',			  # 20 Feb 2014
  'ima-vflCME3y0' => '16128 w8 s2 r w52',			  # 27 Feb 2014
  'ima-vfl1LZyZ5' => '16128 w8 s2 r w52',			  # 27 Feb 2014
  'ima-vfl4_saJa' => '16130 r s1 w19 w9 w57 w38 s3 r s2',	  # 01 Mar 2014
  'ima-en_US-vflP9269H' => '16129 r w63 w37 s3 r w14 r',	  # 06 Mar 2014
  'ima-en_US-vflkClbFb' => '16136 s1 w12 w24 s1 w52 w70 s2',	  # 07 Mar 2014
  'ima-en_US-vflYhChiG' => '16137 w27 r s3',			  # 10 Mar 2014
  'ima-en_US-vflWnCYSF' => '16142 r s1 r s3 w19 r w35 w61 s2',	  # 13 Mar 2014
  'en_US-vflbT9-GA' => '16146 w51 w15 s1 w22 s1 w41 r w43 r',	  # 17 Mar 2014
  'en_US-vflAYBrl7' => '16144 s2 r w39 w43',			  # 18 Mar 2014
  'en_US-vflS1POwl' => '16145 w48 s2 r s1 w4 w35',		  # 19 Mar 2014
  'en_US-vflLMtkhg' => '16149 w30 r w30 w39',			  # 20 Mar 2014
  'en_US-vflbJnZqE' => '16151 w26 s1 w15 w3 w62 w54 w22',	  # 24 Mar 2014
  'en_US-vflgd5txb' => '16151 w26 s1 w15 w3 w62 w54 w22',	  # 25 Mar 2014
  'en_US-vflTm330y' => '16151 w26 s1 w15 w3 w62 w54 w22',	  # 26 Mar 2014
  'en_US-vflnwMARr' => '16156 s3 r w24 s2',			  # 27 Mar 2014
  'en_US-vflTq0XZu' => '16160 r w7 s3 w28 w52 r',		  # 31 Mar 2014
  'en_US-vfl8s5-Vs' => '16158 w26 s1 w14 r s3 w8',		  # 01 Apr 2014
  'en_US-vfl7i9w86' => '16158 w26 s1 w14 r s3 w8',		  # 02 Apr 2014
  'en_US-vflA-1YdP' => '16158 w26 s1 w14 r s3 w8',		  # 03 Apr 2014
  'en_US-vflZwcnOf' => '16164 w46 s2 w29 r s2 w51 w20 s1',	  # 07 Apr 2014
  'en_US-vflFqBlmB' => '16164 w46 s2 w29 r s2 w51 w20 s1',	  # 08 Apr 2014
  'en_US-vflG0UvOo' => '16164 w46 s2 w29 r s2 w51 w20 s1',	  # 09 Apr 2014
  'en_US-vflS6PgfC' => '16170 w40 s2 w40 r w56 w26 r s2',	  # 10 Apr 2014
  'en_US-vfl6Q1v_C' => '16172 w23 r s2 w55 s2',			  # 15 Apr 2014
  'en_US-vflMYwWq8' => '16177 w51 w32 r s1 r s3',		  # 17 Apr 2014
  'en_US-vflGC4r8Z' => '16184 w17 w34 w66 s3',			  # 24 Apr 2014
  'en_US-vflyEvP6v' => '16189 s1 r w26',			  # 29 Apr 2014
  'en_US-vflm397e5' => '16189 s1 r w26',			  # 01 May 2014
  'en_US-vfldK8353' => '16192 r s3 w32',			  # 03 May 2014
  'en_US-vflPTD6yH' => '16196 w59 s1 w66 s3 w10 r w55 w70 s1',	  # 06 May 2014
  'en_US-vfl7KJl0G' => '16196 w59 s1 w66 s3 w10 r w55 w70 s1',	  # 07 May 2014
  'en_US-vflhUwbGZ' => '16200 w49 r w60 s2 w61 s3',		  # 12 May 2014
  'en_US-vflzEDYyE' => '16200 w49 r w60 s2 w61 s3',		  # 13 May 2014
  'en_US-vflimfEzR' => '16205 r s2 w68 w28',			  # 15 May 2014
  'en_US-vfl_nbW1R' => '16206 r w8 r s3',			  # 20 May 2014
  'en_US-vfll7obaF' => '16212 w48 w17 s2',			  # 22 May 2014
  'en_US-vfluBAJ91' => '16216 w13 s1 w39',			  # 27 May 2014
  'en_US-vfldOnicU' => '16217 s2 r w7 w21 r',			  # 28 May 2014
  'en_US-vflbbaSdm' => '16221 w46 r s3 w19 r s2 w15',		  # 03 Jun 2014
  'en_US-vflIpxel5' => '16225 r w16 w35',			  # 04 Jun 2014
  'en_US-vfloyxzv5' => '16232 r w30 s3 r s3 r',			  # 11 Jun 2014
  'en_US-vflmY-xcZ' => '16230 w25 r s1 w49 w52',		  # 12 Jun 2014
  'en_US-vflMVaJmz' => '16236 w12 s3 w56 r s2 r',		  # 17 Jun 2014
  'en_US-vflgt97Vg' => '16240 r s1 r',				  # 19 Jun 2014
  'en_US-vfl19qQQ_' => '16241 s2 w55 s2 r w39 s2 w5 r s3',	  # 23 Jun 2014
  'en_US-vflws3c7_' => '16243 r s1 w52',			  # 24 Jun 2014
  'en_US-vflPqsNqq' => '16243 r s1 w52',			  # 25 Jun 2014
  'en_US-vflycBCEX' => '16247 w12 s1 r s3 w17 s1 w9 r',		  # 26 Jun 2014
  'en_US-vflhZC-Jn' => '16252 w69 w70 s3',			  # 01 Jul 2014
  'en_US-vfl9r3Wpv' => '16255 r s3 w57',			  # 07 Jul 2014
  'en_US-vfl6UPpbU' => '16259 w37 r s1',			  # 08 Jul 2014
  'en_US-vfl_oxbbV' => '16259 w37 r s1',			  # 09 Jul 2014
  'en_US-vflXGBaUN' => '16259 w37 r s1',			  # 10 Jul 2014
  'en_US-vflM1arS5' => '16262 s1 r w42 r s1 w27 r w54',		  # 11 Jul 2014
  'en_US-vfl0Cbn9e' => '16265 w15 w44 r w24 s3 r w2 w50',	  # 14 Jul 2014
  'en_US-vfl5aDZwb' => '16265 w15 w44 r w24 s3 r w2 w50',	  # 15 Jul 2014
  'en_US-vflqZIm5b' => '16268 w1 w32 s1 r s3 r s3 r',		  # 17 Jul 2014
  'en_US-vflBb0OQx' => '16272 w53 r w9 s2 r s1',		  # 22 Jul 2014
  'en_US-vflCGk6yw/html5player' => '16275 s2 w28 w44 w26 w40 w64 r s1', # 24 Jul 2014
  'en_US-vflNUsYw0/html5player' => '16280 r s3 w7',		  # 30 Jul 2014
  'en_US-vflId8cpZ/html5player' => '16282 w30 w21 w26 s1 r s1 w30 w11 w20', # 31 Jul 2014
  'en_US-vflEyBLiy/html5player' => '16283 w44 r w15 s2 w40 r s1',  # 01 Aug 2014
  'en_US-vflHkCS5P/html5player' => '16287 s2 r s3 r w41 s1 r s1 r', # 05 Aug 2014
  'en_US-vflArxUZc/html5player' => '16289 r w12 r s3 w14 w61 r',  # 07 Aug 2014
  'en_US-vflCsMU2l/html5player' => '16292 r s2 r w64 s1 r s3',	  # 11 Aug 2014
  'en_US-vflY5yrKt/html5player' => '16294 w8 r s2 w37 s1 w21 s3', # 12 Aug 2014
  'en_US-vfl4b4S6W/html5player' => '16295 w40 s1 r w40 s3 r w47 r', # 13 Aug 2014
  'en_US-vflLKRtyE/html5player' => '16298 w5 r s1 r s2 r',	  # 18 Aug 2014
  'en_US-vflrSlC04/html5player' => '16300 w28 w58 w19 r s1 r s1 r', # 19 Aug 2014
  'en_US-vflC7g_iA/html5player' => '16300 w28 w58 w19 r s1 r s1 r', # 20 Aug 2014
  'en_US-vfll1XmaE/html5player' => '16303 r w9 w23 w29 w36 s2 r', # 21 Aug 2014
  'en_US-vflWRK4zF/html5player' => '16307 r w63 r s3',		  # 26 Aug 2014
  'en_US-vflQSzMIW/html5player' => '16309 r s1 w40 w70 s2 w28 s1', # 27 Aug 2014
  'en_US-vfltYLx8B/html5player' => '16310 s3 w19 w24',		  # 29 Aug 2014
  'en_US-vflWnljfv/html5player' => '16311 s2 w60 s3 w42 r w40 s2 w68 w20', # 02 Sep 2014
  'en_US-vflDJ-wUY/html5player' => '16316 s2 w18 s2 w68 w15 s1 w45 s1 r', # 04 Sep 2014
  'en_US-vfllxLx6Z/html5player' => '16309 r s1 w40 w70 s2 w28 s1', # 04 Sep 2014
  'en_US-vflI3QYI2/html5player' => '16318 s3 w22 r s3 w19 s1 r',   # 08 Sep 2014
  'en_US-vfl-ZO7j_/html5player' => '16322 s3 w21 s1',		   # 09 Sep 2014
  'en_US-vflWGRWFI/html5player' => '16324 r w27 r s1 r',	   # 12 Sep 2014
  'en_US-vflJkTW89/html5player' => '16328 w12 s1 w67 r w39 w65 s3 r s1', # 15 Sep 2014
  'en_US-vflB8RV2U/html5player' => '16329 r w26 r w28 w38 r s3',   # 16 Sep 2014
  'en_US-vflBFNwmh/html5player' => '16329 r w26 r w28 w38 r s3',   # 17 Sep 2014
  'en_US-vflE7vgXe/html5player' => '16331 w46 w22 r w33 r s3 w18 r s3', # 18 Sep 2014
  'en_US-vflx8EenD/html5player' => '16334 w8 s3 w45 w46 s2 w29 w25 w56 w2', # 23 Sep 2014
  'en_US-vflfgwjRj/html5player' => '16336 r s2 w56 r s3',	   # 24 Sep 2014
  'en_US-vfl15y_l6/html5player' => '16334 w8 s3 w45 w46 s2 w29 w25 w56 w2', # 25 Sep 2014
  'en_US-vflYqHPcx/html5player' => '16341 s3 r w1 r',		   # 30 Sep 2014
  'en_US-vflcoeQIS/html5player' => '16344 s3 r w64 r s3 r w68',	   # 01 Oct 2014
  'en_US-vflz7mN60/html5player' => '16345 s2 w16 w39',		   # 02 Oct 2014
  'en_US-vfl4mDBLZ/html5player' => '16348 r w54 r s2 w49',	   # 06 Oct 2014
  'en_US-vflKzH-7N/html5player' => '16348 r w54 r s2 w49',	   # 08 Oct 2014
  'en_US-vflgoB_xN/html5player' => '16345 s2 w16 w39',		   # 09 Oct 2014
  'en_US-vflPyRPNk/html5player' => '16353 r w34 w9 w56 r s3 r w30', # 12 Oct 2014
  'en_US-vflG0qgr5/html5player' => '16345 s2 w16 w39',		   # 14 Oct 2014
  'en_US-vflzDhHvc/html5player' => '16358 w26 s1 r w8 w24 w18 r s2 r', # 15 Oct 2014
  'en_US-vflbeC7Ip/html5player' => '16359 r w21 r s2 r',	   # 16 Oct 2014
  'en_US-vflBaDm_Z/html5player' => '16363 s3 w5 s1 w20 r',	   # 20 Oct 2014
  'en_US-vflr38Js6/html5player' => '16364 w43 s1 r',		   # 21 Oct 2014
  'en_US-vflg1j_O9/html5player' => '16365 s2 r s3 r s3 r w2',	   # 22 Oct 2014
  'en_US-vflPOfApl/html5player' => '16371 s2 w38 r s3 r',	   # 28 Oct 2014
  'en_US-vflMSJ2iW/html5player' => '16366 s2 r w4 w22 s2 r s2',	   # 29 Oct 2014
  'en_US-vflckDNUK/html5player' => '16373 s3 r w66 r s3 w1 w12 r', # 30 Oct 2014
  'en_US-vflKCJBPS/html5player' => '16374 w15 w2 s1 r s3 r',	   # 31 Oct 2014
  'en_US-vflcF0gLP/html5player' => '16375 s3 w10 s1 r w28 s1 w40 w64 r', # 04 Nov 2014
  'en_US-vflpRHqKc/html5player' => '16377 w39 r w48 r',		   # 05 Nov 2014
  'en_US-vflbcuqSZ/html5player' => '16379 r s1 w27 s2 w5 w7 w51 r', # 06 Nov 2014
  'en_US-vflHf2uUU/html5player' => '16379 r s1 w27 s2 w5 w7 w51 r', # 11 Nov 2014
  'en_US-vfln6g5Eq/html5player' => '16385 w1 r s3 r s2 w10 s3 r',  # 12 Nov 2014
  'en_US-vflM7pYrM/html5player' => '16387 r s2 r w3 r w11 r',	   # 15 Nov 2014
  'en_US-vflP2rJ1-/html5player' => '16387 r s2 r w3 r w11 r',	   # 18 Nov 2014
  'en_US-vflXs0FWW/html5player' => '16392 w63 s1 r w46 s2 r s3',   # 20 Nov 2014
  'en_US-vflEhuJxd/html5player' => '16392 w63 s1 r w46 s2 r s3',   # 21 Nov 2014
  'en_US-vflp3wlqE/html5player' => '16396 w22 s3 r',		   # 24 Nov 2014
  'en_US-vfl5_7-l5/html5player' => '16396 w22 s3 r',		   # 25 Nov 2014
  'en_US-vfljnKokH/html5player' => '16400 s3 w15 s2 w30 w11',	   # 26 Nov 2014
  'en_US-vflIlILAX/html5player' => '16407 r w7 w19 w38 s3 w41 s1 r w1', # 04 Dec 2014
  'en_US-vflEegqdq/html5player' => '16407 r w7 w19 w38 s3 w41 s1 r w1', # 10 Dec 2014
  'en_US-vflkOb-do/html5player' => '16407 r w7 w19 w38 s3 w41 s1 r w1', # 11 Dec 2014
  'en_US-vfllt8pl6/html5player' => '16419 r w17 w33 w53',	   # 16 Dec 2014
  'en_US-vflsXGZP2/html5player' => '16420 s3 w38 s1 w16 r w20 w69 s2 w15', # 18 Dec 2014
  'en_US-vflw4H1P-/html5player' => '16427 w8 r s1',		   # 23 Dec 2014
  'en_US-vflmgJnmS/html5player' => '16421 s3 w20 r w34 r s1 r',	   # 06 Jan 2015
  'en_US-vfl86Quee/html5player' => '16450 s3 r w25 w29 r w17 s2 r', # 15 Jan 2015
  'en_US-vfl19kCnd/html5player' => '16444 r w29 s1 r s1 r w4 w28', # 17 Jan 2015
  'en_US-vflbHLA_P/html5player' => '16451 r w20 r w20 s2 r',	   # 20 Jan 2015
  'en_US-vfl_ZlzZL/html5player' => '16455 w61 r s1 w31 w36 s1',	   # 22 Jan 2015
  'en_US-vflbeV8LH/html5player' => '16455 w61 r s1 w31 w36 s1',	   # 26 Jan 2015
  'en_US-vflhJatih/html5player' => '16462 s2 w44 r s3 w17 s1',	   # 28 Jan 2015
  'en_US-vflvmwLwg/html5player' => '16462 s2 w44 r s3 w17 s1',	   # 29 Jan 2015
  'en_US-vflljBsG4/html5player' => '16462 s2 w44 r s3 w17 s1',	   # 02 Feb 2015
  'en_US-vflT5ziDW/html5player' => '16462 s2 w44 r s3 w17 s1',	   # 03 Feb 2015
  'en_US-vflwImypH/html5player' => '16471 s3 r w23 s2 w29 r w44',  # 05 Feb 2015
  'en_US-vflQkSGin/html5player' => '16475 w70 r w66 s1 w70 w26 r w48', # 10 Feb 2015
  'en_US-vflqnkATr/html5player' => '16475 w70 r w66 s1 w70 w26 r w48', # 11 Feb 2015
  'en_US-vflZvrDTQ/html5player' => '16475 w70 r w66 s1 w70 w26 r w48', # 12 Feb 2015
  'en_US-vflKjOTVq/html5player' => '16475 w70 r w66 s1 w70 w26 r w48', # 17 Feb 2015
  'en_US-vfluEf7CP/html5player' => '16475 w70 r w66 s1 w70 w26 r w48', # 18 Feb 2015
  'en_US-vflF2Mg88/html5player' => '16475 w70 r w66 s1 w70 w26 r w48', # 19 Feb 2015
  'en_US-vflQTSOsS/html5player' => '16489 s3 r w23 s1 w19 w43 w36',    # 24 Feb 2015
  'en_US-vflbaqfRh/html5player' => '16489 s3 r w23 s1 w19 w43 w36',    # 25 Feb 2015
  'en_US-vflcL_htG/html5player' => '16491 w20 s3 w37 r',	  # 04 Mar 2015
  'en_US-vflTbHYa9/html5player' => '16498 s3 w44 s1 r s1 r s3 r s3', # 04 Mar 2015
  'en_US-vflT9SJ6t/html5player' => '16497 w66 r s3 w60',	  # 05 Mar 2015
  'en_US-vfl6xsolJ/html5player' => '16503 s1 w4 s1 w39 s3 r',	  # 10 Mar 2015
  'en_US-vflA6e-lH/html5player' => '16503 s1 w4 s1 w39 s3 r',	  # 13 Mar 2015
  'en_US-vflu7AB7p/html5player' => '16503 s1 w4 s1 w39 s3 r',	  # 16 Mar 2015
  'en_US-vflQb7e_A/html5player' => '16510 w19 w35 r s2 r s1 w64 s2 w53', # 18 Mar 2015
  'en_US-vflicH9X6/html5player' => '16510 w19 w35 r s2 r s1 w64 s2 w53', # 20 Mar 2015
  'en_US-vflvDDxpc/html5player' => '16510 w19 w35 r s2 r s1 w64 s2 w53', # 23 Mar 2015
  'en_US-vflSp2y2y/html5player' => '16510 w19 w35 r s2 r s1 w64 s2 w53', # 24 Mar 2015
  'en_US-vflFAPa9H/html5player' => '16510 w19 w35 r s2 r s1 w64 s2 w53', # 25 Mar 2015
  'en_US-vflImsVHZ/html5player' => '16518 r w1 r w17 s2 r',       # 30 Mar 2015
  'en_US-vfllLRozy/html5player' => '16518 r w1 r w17 s2 r',       # 31 Mar 2015
  'en_US-vfldudhuW/html5player' => '16518 r w1 r w17 s2 r',       # 02 Apr 2015
  'en_US-vfl20EdcH/html5player' => '16511 w12 w18 s1 w60',        # 06 Apr 2015
  'en_US-vflCiLqoq/html5player' => '16511 w12 w18 s1 w60',        # 07 Apr 2015
  'en_US-vflOOhwh5/html5player' => '16518 r w1 r w17 s2 r',       # 09 Apr 2015
  'en_US-vflUPVjIh/html5player' => '16511 w12 w18 s1 w60',        # 09 Apr 2015
  'en_US-vfleI-biQ/html5player' => '16519 w39 s3 r s1 w36',       # 13 Apr 2015
  'en_US-vflWLYnud/html5player' => '16538 r w41 w65 w11 r',       # 14 Apr 2015
  'en_US-vflCbhV8k/html5player' => '16538 r w41 w65 w11 r',       # 15 Apr 2015
  'en_US-vflXIPlZ4/html5player' => '16538 r w41 w65 w11 r',       # 16 Apr 2015
  'en_US-vflJ97NhI/html5player' => '16538 r w41 w65 w11 r',       # 20 Apr 2015
  'en_US-vflV9R5dM/html5player' => '16538 r w41 w65 w11 r',       # 21 Apr 2015
  'en_US-vflkH_4LI/html5player' => '16546 w13 s1 w4 s2 r s2 w25', # 22 Apr 2015
  'en_US-vflfy61br/html5player' => '16546 w13 s1 w4 s2 r s2 w25', # 23 Apr 2015
  'en_US-vfl1r59NI/html5player' => '16548 r w42 s1 r w29 r w2 s2 r',# 28 Apr 2015
  'en_US-vfl98hSpx/html5player' => '16548 r w42 s1 r w29 r w2 s2 r',# 29 Apr 2015
  'en_US-vflheTb7D/html5player' => '16554 r s1 w40 s2 r w6 s3 w60',# 30 Apr 2015
  'en_US-vflnbdC7j/html5player' => '16555 w52 w25 w62 w51 w2 s2 r s1',# 04 May 2015
  'new-en_US-vfladkLoo/html5player-new' => '16555 w52 w25 w62 w51 w2 s2 r s1',# 05 May 2015
  'en_US-vflTjpt_4/html5player' => '16560 w14 r s1 w37 w61 r',    # 07 May 2015
  'en_US-vflN74631/html5player' => '16560 w14 r s1 w37 w61 r',    # 08 May 2015
  'en_US-vflj7H3a2/html5player' => '16560 w14 r s1 w37 w61 r',    # 12 May 2015
  'en_US-vflQbG2p4/html5player' => '16560 w14 r s1 w37 w61 r',    # 12 May 2015
  'en_US-vflHV7Wup/html5player' => '16560 w14 r s1 w37 w61 r',    # 13 May 2015
  'en_US-vflCbZ69_/html5player' => '16574 w3 s3 w45 r w3 w2 r w13 r',# 20 May 2015
  'en_US-vflugm_Hi/html5player' => '16574 w3 s3 w45 r w3 w2 r w13 r',# 21 May 2015
  'en_US-vfl3tSKxJ/html5player' => '16577 w37 s3 w57 r w5 r w13 r',# 26 May 2015
  'en_US-vflE8_7k0/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 28 May 2015
  'en_US-vflmxRINy/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 01 Jun 2015
  'en_US-vflQEtHy6/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 02 Jun 2015
  'en_US-vflRqg76I/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 03 Jun 2015
  'en_US-vfloIm75c/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 04 Jun 2015
  'en_US-vfl0JH6Oo/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 08 Jun 2015
  'en_US-vflHvL0kQ/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 09 Jun 2015
  'new-en_US-vflGBorXT/html5player-new' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 10 Jun 2015
  'en_US-vfl4Y6g4o/html5player' => '16582 r w41 s3 w69 s1 w66 r w27 s2',# 11 Jun 2015
  'en_US-vflKAbZ28/html5player' => '16597 s3 r s2',               # 15 Jun 2015
  'en_US-vflM5YBLT/html5player' => '16602 s2 w25 w14 s1 r',       # 17 Jun 2015
  'en_US-vflnSSUZV/html5player' => '16603 w20 s2 w11 s3 r s1 w2 w15',# 18 Jun 2015
  'en_US-vfla1HjWj/html5player' => '16603 w20 s2 w11 s3 r s1 w2 w15',# 22 Jun 2015
  'en_US-vflPcWTEd/html5player' => '16603 w20 s2 w11 s3 r s1 w2 w15',# 23 Jun 2015
  'en_US-vfljL8ofl/html5player' => '16609 w29 r s1 r w59 r w45',  # 25 Jun 2015
  'en_US-vflUXoyA8/html5player' => '16609 w29 r s1 r w59 r w45',  # 29 Jun 2015
  'en_US-vflzomeEU/html5player' => '16609 w29 r s1 r w59 r w45',  # 30 Jun 2015
  'en_US-vflihzZsw/html5player' => '16617 s3 r s3 w17',           # 07 Jul 2015
  'en_US-vfld2QbH7/html5player' => '16623 w58 w46 s1 w9 r w54 s2 r w55',# 08 Jul 2015
  'en_US-vflVsMRd_/html5player' => '16623 w58 w46 s1 w9 r w54 s2 r w55',# 09 Jul 2015
  'en_US-vflp6cSzi/html5player' => '16625 w52 w23 s1 r s2 r s2 r',# 16 Jul 2015
  'en_US-vflr_ZqiK/html5player' => '16625 w52 w23 s1 r s2 r s2 r',# 20 Jul 2015
  'en_US-vflDv401v/html5player' => '16636 r w68 w58 r w28 w44 r', # 21 Jul 2015
  'en_US-vflP7pyW6/html5player' => '16636 r w68 w58 r w28 w44 r', # 22 Jul 2015
  'en_US-vfly-Z1Od/html5player' => '16636 r w68 w58 r w28 w44 r', # 23 Jul 2015
  'en_US-vflSxbpbe/html5player' => '16636 r w68 w58 r w28 w44 r', # 27 Jul 2015
  'en_US-vflGx3XCd/html5player' => '16636 r w68 w58 r w28 w44 r', # 29 Jul 2015
  'new-en_US-vflIgTSdc/html5player-new' => '16648 r s2 r w43 w41 w8 r w67 r',# 03 Aug 2015
  'new-en_US-vflnk2PHx/html5player-new' => '16651 r w32 s3 r s1 r',# 06 Aug 2015
  'new-en_US-vflo_te46/html5player-new' => '16652 r s2 w27 s1',   # 06 Aug 2015
  'new-en_US-vfllZzMNK/html5player-new' => '16657 w11 w29 w63 r w45 w34 s2',# 11 Aug 2015
  'new-en_US-vflxgfwPf/html5player-new' => '16657 w11 w29 w63 r w45 w34 s2',# 13 Aug 2015
  'new-en_US-vflTSd4UU/html5player-new' => '16657 w11 w29 w63 r w45 w34 s2',# 14 Aug 2015
  'new-en_US-vfl2Ys-gC/html5player-new' => '16657 w11 w29 w63 r w45 w34 s2',# 15 Aug 2015
  'new-en_US-vflRWS2p7/html5player-new' => '16657 w11 w29 w63 r w45 w34 s2',# 19 Aug 2015
  'new-en_US-vflVBD1Nz/html5player-new' => '16657 w11 w29 w63 r w45 w34 s2',# 20 Aug 2015
  'new-en_US-vflJVflpM/html5player-new' => '16667 r s1 r w8 r w5 s2 w30 w66',# 24 Aug 2015
  'en_US-vfleu-UMC/html5player' => '16667 r s1 r w8 r w5 s2 w30 w66',# 26 Aug 2015
  'new-en_US-vflOWWv0e/html5player-new' => '16667 r s1 r w8 r w5 s2 w30 w66',# 26 Aug 2015
  'new-en_US-vflyGTTiE/html5player-new' => '16674 w68 s3 w66 s1 r',# 01 Sep 2015
  'new-en_US-vflCeB3p5/html5player-new' => '16674 w68 s3 w66 s1 r',# 02 Sep 2015
  'new-en_US-vflhlPTtB/html5player-new' => '16682 w40 s3 w53 w11 s3 r s3 w16 r',# 09 Sep 2015
  'new-en_US-vflSnomqH/html5player-new' => '16689 w56 w12 r w26 r',# 16 Sep 2015
  'new-en_US-vflkiOBi0/html5player-new' => '16696 w55 w69 w61 s2 r',# 22 Sep 2015
  'new-en_US-vflpNjqAo/html5player-new' => '16696 w55 w69 w61 s2 r',# 22 Sep 2015
  'new-en_US-vflOdTWmK/html5player-new' => '16696 w55 w69 w61 s2 r',# 23 Sep 2015
  'new-en_US-vfl9jbnCC/html5player-new' => '16703 s1 r w18 w67 r s3 r',# 29 Sep 2015
  'new-en_US-vflyM0pli/html5player-new' => '16696 w55 w69 w61 s2 r',# 29 Sep 2015
  'new-en_US-vflJLt_ns/html5player-new' => '16708 w19 s2 r s2 w48 r s2 r',# 30 Sep 2015
  'new-en_US-vflqLE6s6/html5player-new' => '16708 w19 s2 r s2 w48 r s2 r',# 02 Oct 2015
  'new-en_US-vflzRMCkZ/html5player-new' => '16711 r s3 r s2 w62 w25 s1 r',# 04 Oct 2015
  'new-en_US-vflIUNjzZ/html5player-new' => '16711 r s3 r s2 w62 w25 s1 r',# 08 Oct 2015
  'new-en_US-vflOw5Ej1/html5player-new' => '16711 r s3 r s2 w62 w25 s1 r',# 08 Oct 2015
  'new-en_US-vflq2mOFv/html5player-new' => '16714 r w37 r w19 r s3 r w5',# 12 Oct 2015
  'new-en_US-vfl8AWn6F/html5player-new' => '16714 r w37 r w19 r s3 r w5',# 13 Oct 2015
  'new-en_US-vflEA2BSM/html5player-new' => '16714 r w37 r w19 r s3 r w5',# 14 Oct 2015
  'new-en_US-vflt2Xpp6/html5player-new' => '16717 r s1 w14',      # 15 Oct 2015
  'new-en_US-vflDpriqR/html5player-new' => '16714 r w37 r w19 r s3 r w5',# 15 Oct 2015
  'new-en_US-vflptVjJB/html5player-new' => '16723 s2 r s3 w54 w60 w55 w65',# 21 Oct 2015
  'new-en_US-vflmR8A04/html5player-new' => '16725 w28 s2 r',      # 23 Oct 2015
  'new-en_US-vflx6L8FI/html5player-new' => '16735 r s2 r w65 w1 s1',# 27 Oct 2015
  'new-en_US-vflYZP7XE/html5player-new' => '16734 s1 r s1 w56 w46 s2 r',# 27 Oct 2015
  'new-en_US-vflQZZsER/html5player-new' => '16734 s1 r s1 w56 w46 s2 r',# 29 Oct 2015
  'new-en_US-vflsLAYSi/html5player-new' => '16734 s1 r s1 w56 w46 s2 r',# 29 Oct 2015
  'new-en_US-vflZWDr6u/html5player-new' => '16734 s1 r s1 w56 w46 s2 r',# 02 Nov 2015
  'new-en_US-vflJoRj2J/html5player-new' => '16742 w69 w47 r s1 r s1 r w43 s2',# 03 Nov 2015
  'new-en_US-vflFSFCN-/html5player-new' => '16734 s1 r s1 w56 w46 s2 r',# 04 Nov 2015
  'new-en_US-vfl6mEKMp/html5player-new' => '16734 s1 r s1 w56 w46 s2 r',# 05 Nov 2015
 'player-en_US-vflJENbn4/base' => '16748 s1 w31 r',              # 12 Nov 2015
   'player-en_US-vfltBCT02/base' => '16756 r s2 r w18 w62 w45 s1', # 17 Nov 2015
  'player-en_US-vfl0w9xAB/base' => '16756 r s2 r w18 w62 w45 s1', # 17 Nov 2015
  'player-en_US-vflCIicNM/base' => '16759 w2 s3 r w38 w21 w58',   # 20 Nov 2015
  'player-en_US-vflUpjAy9/base' => '16758 w26 s3 r s3 r s3 w61 s3 r',# 23 Nov 2015
  'player-en_US-vflFEzfy7/base' => '16758 w26 s3 r s3 r s3 w61 s3 r',# 24 Nov 2015
  'player-en_US-vfl_RJZIW/base' => '16770 w3 w2 s3 w39 s2 r s2',  # 01 Dec 2015
  'player-en_US-vfln_PDe6/base' => '16770 w3 w2 s3 w39 s2 r s2',  # 03 Dec 2015
  'player-en_US-vflx9OkTA/base' => '16772 s2 w50 r w15 w66 s3',   # 07 Dec 2015
);


my $cipher_warning_printed_p = 0;
sub decipher_sig($$$) {
  my ($id, $cipher, $signature) = @_;

  return $signature unless defined ($cipher);

  my $orig = $signature;
  my @s = split (//, $signature);

  my $c = $ciphers{$cipher};
  if (! $c) {
    print STDERR "$progname: WARNING: $id: unknown cipher $cipher!\n"
      if ($verbose > 0 && !$cipher_warning_printed_p);
    $c = guess_cipher ($cipher, 0, $cipher_warning_printed_p);
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

  return $signature;
}


# Total kludge that downloads the current html5player, parses the JavaScript,
# and intuits what the current cipher is.  Normally we go by the list of
# known ciphers above, but if that fails, we try and do it the hard way.
#
sub guess_cipher(;$$) {
  my ($cipher_id, $selftest_p, $nowarn) = @_;

  # If we're in cipher-guessing mode, crank up the verbosity to also
  # mention the list of formats and which format we ended up choosing.
  $verbose = 2 if ($verbose == 1 && !$selftest_p);


  my $url = "http://www.youtube.com/";
  my ($http, $head, $body);
  my $id = '-';

  if (! $cipher_id) {
    ($http, $head, $body) = get_url ($url);		# Get home page
    check_http_status ('-', $url, $http, 2);

    my @vids = ();
    $body =~ s%/watch\?v=([^\"\'<>]+)%{
      push @vids, $1;
      '';
    }%gsex;

    errorI ("no  videos found on home page $url") unless @vids;

    # Get random video -- pick one towards the middle, because sometimes
    # the early ones are rental videos.
    my $id = @vids[int(@vids / 2)];
    $url .= "/watch\?v=$id";

    ($http, $head, $body) = get_url ($url);	# Get random video's info
    check_http_status ($id, $url, $http, 2);

    $body =~ s/\\//gs;
    ($cipher_id) = ($body =~ m@/jsbin\\?/((?:html5)?player-.+?)\.js@s);
    errorI ("$id: unparsable cipher url: $url\n\nBody:\n\n$body")
      unless $cipher_id;
  }

  $cipher_id =~ s@\\@@gs;
  $url = "http://s.ytimg.com/yts/jsbin/$cipher_id.js";

  ($http, $head, $body) = get_url ($url);
  check_http_status ($id, $url, $http, 2);

  my ($date) = ($head =~ m/^Last-Modified:\s+(.*)$/mi);
  $date =~ s/^[A-Z][a-z][a-z], (\d\d? [A-Z][a-z][a-z] \d{4}).*$/$1/s;

  my $v = '[\$a-zA-Z][a-zA-Z\d]*';	# JS variable

  $v = "$v(?:\.$v)?";   # Also allow "a.b" where "a" would be used as a var.


  # First, find the sts parameter:
  my ($sts) = ($body =~ m/\bsts:(\d+)\b/si);
  errorI ("$cipher_id: no sts parameter: $url") unless $sts;


  # Since the script is minimized and obfuscated, we can't search for
  # specific function names, since those change. Instead we match the
  # code structure.
  #
  # Note that the obfuscator sometimes does crap like y="split",
  # so a[y]("") really means a.split("")


  # Find "C" in this: var A = B.sig || C (B.s)
  my (undef, $fn) = ($body =~ m/$v = ( $v ) \.sig \|\| ( $v ) \( \1 \.s \)/sx);
  errorI ("$cipher_id: unparsable cipher js: $url") unless $fn;

  # Find body of function C(D) { ... }
  # might be: var C = function(D) { ... }
  my ($fn2) = ($body =~ m@\b function \s+ \Q$fn\E \s* \( $v \)
                          \s* { ( .*? ) } @sx);
     ($fn2) = ($body =~ m@\b var \s+ \Q$fn\E \s* = \s* function \s* \( $v \)
                          \s* { ( .*? ) } @sx);

  errorI ("$cipher_id: unparsable fn \"$fn\"") unless $fn2;

  $fn = $fn2;

  # They inline the swapper if it's used only once.
  # Convert "var b=a[0];a[0]=a[63%a.length];a[63]=b;" to "a=swap(a,63);".
  $fn2 =~ s@
            var \s ( $v ) = ( $v ) \[ 0 \];
            \2 \[ 0 \] = \2 \[ ( \d+ ) % \2 \. length \];
            \2 \[ \3 \]= \1 ;
           @$2=swap($2,$3);@sx;

  my @cipher = ();
  foreach my $c (split (/\s*;\s*/, $fn2)) {
    if      ($c =~ m@^ ( $v ) = \1 . $v \(""\) $@sx) {         # A=A.split("");
    } elsif ($c =~ m@^ ( $v ) = \1 .  $v \(\)  $@sx) {         # A=A.reverse();
      push @cipher, "r";
    } elsif ($c =~ m@^ ( $v ) = \1 . $v \( (\d+) \) $@sx) {    # A=A.slice(N);
      push @cipher, "s$2";

    } elsif ($c =~ m@^ ( $v ) = ( $v ) \( \1 , ( \d+ ) \) $@sx ||  # A=F(A,N);
             $c =~ m@^ (    )   ( $v ) \( $v , ( \d+ ) \) $@sx) {  # F(A,N);
      my $f = $2;
      my $n = $3;
      $f =~ s/^.*\.//gs;  # C.D => D
      # Find function D, of the form: C={ ... D:function(a,b) { ... }, ... }
      my ($fn3) = ($body =~ m@ \b \Q$f\E: \s*
                               function \s* \( .*? \) \s*
                                ( { [^{}]+ } )
                             @sx);
      # Look at body of D to decide what it is.
      if ($fn3 =~ m@ var \s ( $v ) = ( $v ) \[ 0 \]; @sx) {  # swap
        push @cipher, "w$n";
      } elsif ($fn3 =~ m@ \b $v \. reverse\( @sx) {          # reverse
        push @cipher, "r";
      } elsif ($fn3 =~ m@ return \s* $v \. slice @sx ||      # slice
               $fn3 =~ m@ \b $v \. splice @sx) {             # splice
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

  open (my $in, '<', $progname0) || error ("$progname0: $!");
  local $/ = undef;  # read entire file  
  my ($body) = <$in>;
  close $in;

  $body =~ s@(\nmy %ciphers = .*?)(\);)@$1$cipher_line\n$2@s ||
    error ("auto-update: unable to splice");

  # Since I'm not using CVS any more, also update the version number.
  $body =~ s@([\$]Revision:\s+\d+\.)(\d+)(\s+[\$])@
             { $1 . ($2 + 1) . $3 }@sexi ||
    error ("auto-update: unable to tick version");

  open (my $out, '>', $progname0) || error ("$progname0: $!");
  print $out $body;
  close $out;
  print STDERR "$progname: auto-updated $progname0\n";

  # This part isn't expected to work for you.
  my ($dir) = $ENV{HOME} . '/www/hacks';
  system ("cd '$dir'" .
          " && git commit -q -m 'cipher auto-update' '$progname'" .
          " && git push -q")
    if -d $dir;
}


# For verifying that decipher_sig() implements exactly the same transformation
# that the JavaScript implementations do.
#
sub decipher_selftest() {
  my $tests = {
#   'UNKNOWN 88' . "\t" .
#   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGHIJ.' .		# 88
#   'LMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvw' =>
#   'Pqponmlkjihgfedrba`_u]\\[ZYXWVUTSRQcONML.' .
#   'JIHGFEDCBA@?>=<;:9876543210/x-#+*)(\'&%$",',

   'vflmOfVEX' . "\t" .
   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGHIJ.' .		# 87
   'LMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuv' =>
   '^rqponmlkjihgfedcba`_s]\\[ZYXWVU SRQPONML.' .
   'JIHGFEDCBA@?>=<;:9876543210/x-,+*)(\'&%$#',

   'vfl_ymO4Z' . "\t" .
   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGHI.' .		# 86
   'KLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstu' =>
   '"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGHI.' .
   'KLMNOPQRSTUVWXYZ[\]^r`abcdefghijklmnopq_',

   'vfltM3odl' . "\t" .
   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGHI.' .		# 85
   'KLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrst' =>
   'lrqponmskjihgfedcba`_^] [ZYXWVUTS!QPONMLK.' .
   'IHGFEDCBA@?>=<;:9876543210/x-,+*)(\'&%$#',

#   'UNKNOWN 84' . "\t" .
#   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGH.' .		# 84
#   'JKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrs' =>
#   'srqponmlkjihgfedcba`_^]\\[ZYXWVUTSRQPONMLKJ.' .
#   'HGFE"CBA@?>=<;#9876543210/x-,+*)(\'&%$:',

#   'UNKNOWN 83' . "\t" .
#   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFGH.' .		# 83
#   'JKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqr' =>
#   'Tqponmlkjihgfedcba`_^]\\[ZYX"VUrSRQPONMLKJ.' .
#   'HGFEWCBA@?>=<;:9876543210/x-,+*)(\'&%$#D',

#   'UNKNOWN 82' . "\t" .
#   ' !"#$%&\'()*+,-x/0123456789:;<=>?@ABCDEFG.' .		# 82
#   'IJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopq' =>
#   'Donmlkjihgfedqba`_^]\\[ZYXWVUTSRQPONMLKJIAGFE.' .
#   'C c@?>=<;:9876543210/x-,+*)(\'&%$#"!B',

   'vflmOfVEX' . "\t" .
   '5AEEAE0EC39677BC65FD9021CCD115F1F2DBD5A59E4.' .		# Real examples
   'C0B243A3E2DED6769199AF3461781E75122AE135135' =>		# 87
   '931EA22157E1871643FA9519676DED253A342B0C.' .
   '4E95A5DBD2F1F511DCC1209DF56CB77693CE0EAE',

   'vflmOfVEX' . "\t" .
   '7C03C0B9B947D9DCCB27CD2D1144BA8F91B7462B430.' .		# 87
   '8CFE5FA73DDE66DCA33BF9F902E09B160BC42924924' =>
   '32924CB061B90E209F9FB43ACD66EDD77AF5EFC8.' .
   '034B2647B19F8AB4411D2DC72BCCD9D749B9B0C3',

   'vflmOfVEX' . "\t" .
   '38A48AA6FAC88C2240DEBE5F74F4E62DC1F0828E990.' .		# 87
   '53B824774161BD7CE735CA84963AA17B002D1901901' =>
   '3091D200B71AA36948AC517EC7DB161377428B35.' .
   '099E8280F1CD26E4F47F5EBED0422C88CAF6AA84',

   'vfl_ymO4Z' . "\t" .
   '7272B1BA35548BA3939F9CE39C4E72A98BB78ABB28.' .		# 86
   '560A7424D42FF070C115935232F8BDB8A1F3E05C05C' =>
   '72B1BA35548BA3939F9CE39C4E72A98BB78ABB28.' .
   '560A7424D42FF070C115C35232F8BDB8A1F3E059',

   'vflmOfVEX' . "\t" .
   'CFDEFDEBFC25C1BA6E940A10E4ED8326FD4EDDD0B1A.' .   # 87 from "watch?v="
   '22F7E77BE9637FBE657ED4FDE0DEE96F06CB011D11D' =>
#  '61661661658E036DF1B58C21783028FE116E7DB7C62B.' .  # corresponding sig
#  'D225BE11FBCBD59C62F163A57BF8EC1B47897485E85E' =>  # from "get_video_info"
   '7110BC60F69EED0EDF4DED56EBF7369CB77E7F22.' .
   'A1B0DDDE4DF6238DE4E01A049E6AB1C52CFBEDFE',

   'en_US-vfl0Cbn9e' . "\t" .
   '9977B9CA5435687412E6E3436260447A98CA0268.' .
   '83C3A50B214CE0D9279695F4B5A31FEFEC4CFAA9AA5' =>
   '1937B9CA5435687912E6E3436260447A98CA0268.' .
   '83C4A50B274CE0D9275695F4B5A31FEFEC4CFAA9',
  };

  my %verified;
  foreach my $key (sort { my ($aa, $bb) = ($a, $b);
                          foreach ($aa, $bb) { s/^.*?\t//s; }
                          length($aa) == length($bb)
                          ? $aa cmp $bb
                          : length($aa) <=> length($bb) }
                   keys (%$tests)) {
    my $expect = $tests->{$key};
    my ($cipher, $sig) = split (/\t/, $key);
    my $id = $cipher . " " . length ($sig);
    my $got = decipher_sig ($id, $cipher, $sig);
    my $L2 = length ($got);
    if ($expect eq $got) {
      my $v = ($key !~ m/ABCDEF/s);
      print STDERR "$id: OK ($L2) $got\n";
      $verified{$id} = $verified{$id} || $v;
    }
    else { print STDERR "$id: FAIL: $got\n"; }
  }
  my @un = ();
  foreach my $k (sort (keys %verified)) {
    push @un, $k unless $verified{$k};
  }
  print STDERR "Unverified: " . join(', ', @un) . "\n";
}

# decipher_selftest(); exit();


# Replace the signature in the URL, deciphering it first if necessary.
#
sub apply_signature($$$$$) {
  my ($id, $fmt, $url, $cipher, $sig) = @_;
  if ($sig) {
    if (defined ($cipher)) {
      my $o = $sig;
      $sig = decipher_sig ("$id/$fmt", $cipher, $sig);
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
        $error_whiteboard .= "\n" if $error_whiteboard;
        $error_whiteboard .= "$fmt:       " .
                             "http://www.youtube.com/watch?v=$id\n$s";
        if ($verbose > 3) {
          print STDERR "$progname: $id: deciphered and replaced signature\n";
          $s =~ s/^([^ ]+)(  )/$2$1/s;
          $s =~ s/^/$progname:    /gm;
          print STDERR "$s\n";
        }
      }
    }
    $url =~ s@&signature=[^&]+@@gs;
    $url .= '&signature=' . $sig;
  }
  return $url;
}




# Convert the text of a Youtube urlmap field into a structure.
# Apply signatures to enclosed URLs as necessary.
# Returns a hashref, or undef if the signatures could not be applied.
#
sub youtube_parse_urlmap($$$) {
  my ($id, $urlmap, $cipher) = @_;

  my $cipher_printed_p = 0;

  my %fmts;
  foreach (split (/,/, $urlmap)) {
    # Format used to be: "N|url,N|url,N|url"
    # Now it is: "url=...&quality=hd720&fallback_host=...&type=...&itag=N"
    my ($k, $v, $e, $sig, $sig2);
    if (m/^\d+\|/s) {
      ($k, $v) = m/^(.*?)\|(.*)$/s;
    } elsif (m/^[a-z][a-z\d_]*=/s) {

      ($sig)  = m/\bsig=([^&]+)/s;	# sig= when un-ciphered.
      ($sig2) = m/\bs=([^&]+)/s;	# s= when enciphered.

      ($k) = m/\bitag=(\d+)/s;
      ($v) = m/\burl=([^&]+)/s;
      $v = url_unquote($v) if ($v);

      my ($q) = m/\bquality=([^&]+)/s;
      my ($t) = m/\btype=([^&]+)/s;
      $t = url_unquote($t) if ($t);
      if ($q && $t) {
        $e = "\t$q, $t";
      } elsif ($t) {
        $e = $t;
      }
      $e = url_unquote($e) if ($e);
    }

    error ("$id: can't download RTMPE DRM videos")
      # There was no indiciation in get_video_info that this is an RTMPE
      # stream, so it took us several retries to fail here.
      if (!$v && $urlmap =~ m/\bconn=rtmpe%3A/s);

    errorI ("$id: unparsable urlmap entry: no itag: $_") unless ($k);
    errorI ("$id: unparsable urlmap entry: no url: $_")  unless ($v);

    my ($ct) = ($e =~ m@\b((audio|video|text|application)/[-_a-z\d]+)\b@si);

    $v =~ s@^.*?\|@@s;  # VEVO

    if ($verbose > 1 && !$cipher_printed_p) {
      print STDERR "$progname: $id: " .
                   ($sig2 ? "enciphered" : "non-enciphered") .
                   ($sig2 && $cipher ? " ($cipher)" : "") . "\n";
      $cipher_printed_p = 1;
    }

    # If we have an enciphered sig, but don't know the cipher, we have to
    # go through the HTML path.
    #
    if ($sig2 && !$cipher) {
      print STDERR "$progname: $id: enciphered sig.  Scraping HTML...\n"
        if ($verbose > 1);
      return undef;
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
    $v = apply_signature ($id, $k, $v,
                          $sig2 ? $cipher : undef,
                          $sig || $sig2);

    # Finally! The "ratebypass" parameter turns off rate limiting!
    # But we can't add it to a URL that signs the "ratebypass" parameter,
    # which (currently, at least) is format 18, which is not rate-limited
    # anyway.
    #
    $v .= '&ratebypass=yes'
      unless ($v =~ m@sparams=[^?&]*ratebypass@);

    print STDERR "\t\t$k\t$v\t$e\n" if ($verbose > 3);

    my %v = ( fmt  => $k,
              url  => $v,
              content_type => $ct,
            # w    => undef,
            # h    => undef,
            # size => undef,
            # abr  => undef,
            );

    $fmts{$k} = \%v;
  }

  return \%fmts;
}


# This version parses the HTML instead of get_video_info,
# in the case where get_video_info didn't work.
# #### But does that case still exist, now that we use "sts"?
#
sub load_youtube_formats_html($$$) {
  my ($id, $url, $oerror) = @_;

  my ($http, $head, $body) = get_url ($url);

  my ($title) = ($body =~ m@<title>\s*(.*?)\s*</title>@si);
  $title = munge_title (html_unquote ($title || ''));

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

  my $blocked_re = join ('|',
                         ('(available|blocked it) in your country',
                          'copyright (claim|grounds)',
                          'removed by the user',
                          'is not available'));

  if (! $args) {
    # Try to find a better error message
    my (undef, $err) = ($body =~ m@<( div | h1 ) \s+
                                    (?: id | class ) = 
                                   "(?: error-box |
                                        yt-alert-content |
                                        unavailable-message )"
                                   [^<>]* > \s* 
                                   ( [^<>]+? ) \s*
                                   </ \1 > @six);
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

      $err = "$err ($title)" if ($title);

      $oerror = $err;
      $http = 'HTTP/1.0 404';
    }
  }

  if ($verbose <= 0 && $oerror =~ m/$blocked_re/sio) {
    # With --quiet, just silently ignore country-locked video failures,
    # for "youtubefeed".
    exit (0);
  }

  # Sometimes Youtube returns HTTP 404 pages that have real messages in them,
  # so we have to check the HTTP status late. But sometimes it doesn't return
  # 404 for pages that no longer exist. Hooray.

  $http = 'HTTP/1.0 404'
    if ($oerror && $oerror =~ m/$blocked_re/sio);
  error ("$id: $http: $oerror")
    unless (check_http_status ($id, $url, $http, 0));
  errorI ("$id: no ytplayer.config$oerror")
    unless $args;

  my ($kind, $kind2, $urlmap, $urlmap2);

  ($kind, $urlmap) = ($args =~ m@"(fmt_url_map)": *"(.*?)"@s)
    unless $urlmap;
  ($kind, $urlmap) = ($args =~ m@"(fmt_stream_map)": *"(.*?)"@s)  # VEVO
    unless $urlmap;
  ($kind, $urlmap) = ($args =~ m@"(url_encoded_fmt_stream_map)": *"(.*?)"@s)
    unless $urlmap;			   # New nonsense seen in Aug 2011

  ($kind2, $urlmap2) = ($args =~ m@"(adaptive_fmts)": *"(.*?)"@s)
    unless $urlmap2;

  if (! $urlmap) {
    if ($body =~ m/This video has been age-restricted/s) {
      error ("$id: enciphered but age-restricted$oerror");
    }
    errorI ("$id: no fmt_url_map$oerror");
  }

  $kind = $kind2 if $kind2;
  print STDERR "$progname: $id: found $kind in HTML\n"
    if ($kind && $verbose > 1);

  my ($cipher) = ($body =~ m@/jsbin\\?/((?:html5)?player-.+?)\.js@s);
  $cipher =~ s@\\@@gs if $cipher;

  return ($title, $urlmap, $urlmap2, $cipher);
}



# Returns a hash of: 
#  [ title: "T",
#    N: [ ...video info... ],
#    M: [ ...video info... ], ... ]
#
sub load_youtube_formats($$) {
  my ($id, $url) = @_;

  my $cipher = undef;
  my $sts = undef;

  # Let's just use an old cipher. Doing this allows us to download
  # videos that are both enciphered and "content warning".
  #
  # But not all old ciphers work!  Though all of them used to.
  #
  # Current theory is that as of 4-Mar-2015, only 'sts' values >= 16497
  # work. Which means the first three still work, and more recent ones.
  #
  # And as of 31-Mar-2015, 16497 stopped working, but the next one, 16503,
  # still works.  So they are expiring them now, after something less than
  # a month.  But the three really old ones (135957536242, etc.)  still
  # work -- possibly only because those are larger numbers?
  #
  # The large sts numbers are time_t in 1/100th sec. The smaller numbers are
  # who-knows-what, and are sorted alphabetically rather than numerically,
  # so "1588" == "15880" and "16" == "16000".  Yeah, really.
  #
  $cipher = 'vflNzKG7n';  # This is our oldest cipher, 30-Jan-2013.

  if ($cipher) {
    $sts = $1 if ($ciphers{$cipher} =~ m/^\s*(\d+)\s/si);
    errorI ("$cipher: no sts") unless $sts;
  }

  my $info_url = ("http://www.youtube.com/get_video_info?video_id=$id" .
                  # Avoid the "playback restricted" error. This is a referer.
                  '&eurl=' . url_quote ($url) .
                  ($sts ? '&sts=' . $sts : '')
                 );
  my ($title, $kind, $kind2, $urlmap, $urlmap2, $body, $rental, $realtime,
      $rtmpe_p, $embed_p, $dashmpd);

  my $retries = 5;
  my $err = undef;

  while (--$retries) {	# Sometimes the $info_url fails; try a few times.

    my ($http, $head);
    ($http, $head, $body) = get_url ($info_url);
    $err = (check_http_status ($id, $url, $http, 0) ? undef : $http);

    ($kind, $urlmap) = ($body =~ m@&(fmt_url_map)=([^&]+)@si)
      unless $urlmap;
    ($kind, $urlmap) = ($body =~ m@&(fmt_stream_map)=([^&]+)@si)	# VEVO
      unless $urlmap;
    ($kind, $urlmap) = ($body =~ m@&(url_encoded_fmt_stream_map)=([^&]+)@si) 
      unless $urlmap;			   # New nonsense seen in Aug 2011

    ($kind2, $urlmap2) = ($body =~ m@&(adaptive_fmts)=([^&]+)@si)	# 2014
      unless $urlmap2;

    if (!$err &&
        $body =~ m/\bstatus=fail\b/si &&
        $body =~ m/\breason=([^?&]+)/si) {
      $err = url_unquote ($1);
    }

    ($title)    = ($body =~ m@&title=([^&]+)@si) unless $title;
    ($rental)   = ($body =~ m@&ypc_video_rental_bar_text=([^&]+)@si);
    ($realtime) = ($body =~ m@&(?:livestream|live_playback|hlsvp)=([^&]+)@si);
    ($embed_p)  = ($body =~ m@&allow_embed=([^&]+)@si);
    $rtmpe_p    = ($urlmap && $urlmap =~ m/rtmpe(=|%3D|%253D)yes/s);
    ($dashmpd)  = ($body =~ m@&dashmpd=([^&]+)@s);
    $dashmpd = url_unquote($dashmpd) if $dashmpd;

    $embed_p = 0 if (!defined($embed_p) &&
                     $body =~ m/on[\s+]other[\s+]websites/s);

    $kind = $kind2 if $kind2;
    print STDERR "$progname: $id: found $kind in JSON" .
                 (defined($embed_p)
                  ? ($embed_p ? " (embeddable)" : " (non-embeddable)")
                  : "") .
                 "\n"
      if ($kind && $verbose > 1);

    last if ($rental || $realtime || $rtmpe_p ||
             ($urlmap && $urlmap2 && $title) ||
             (defined($embed_p) && !$embed_p));

    if ($verbose > 0) {
      if (!$urlmap2) {
        print STDERR "$progname: $id: no adaptive_fmts, retrying...\n";
      } elsif (! $urlmap) {
        print STDERR "$progname: $id: no fmt_url_map, retrying...\n";
      } else {
        print STDERR "$progname: $id: no title, retrying...\n";
      }
    }

    sleep (1);
  }

  $err = "video is not embeddable"
    if ($err && (defined($embed_p) && !$embed_p));

  if ($err && (defined($embed_p) && !$embed_p)) {
    # Ignore the embed error and go on to HTML scraping.
    $err = undef;
  }

  $err = "can't download rental videos"
    if (!$err && !$urlmap && $rental);

  $err = "can't download livestream videos"
    if (!$err && !$urlmap && $realtime);

  $err = "can't download RTMPE DRM videos"
    if (!$err && $rtmpe_p);

  if ($verbose <= 0 && $err &&
      $err =~ m/livestream|rtmpe|sign in to view/sio) {
    # With --quiet, just silently ignore livestream failures,
    # for "youtubefeed".
    exit (0);
  }

  if ($err && $verbose <= 0) {
    my $blocked_re = join ('|',
                         ('(available|blocked it) in your country',
                          'copyright (claim|grounds)',
                          'removed by the user',
                          'is not available',
                          'is not embeddable'));
    if ($err =~ m/$blocked_re/sio) {
      # With --quiet, just silently ignore country-locked video failures,
      # for "youtubefeed".
      exit (0);
    }
  }

  error ("$progname: $id: $err")
    if $err;

  ($title) = ($body =~ m@&title=([^&]+)@si) unless $title;
  errorI ("$id: no title in $info_url") if (!$title && $urlmap);
  $title = url_unquote($title) if $title;

  my $fmts = undef;

  if (! $urlmap) {
    print STDERR "$progname: $id: no fmt_url_map" .
                 (defined($embed_p)
                  ? ($embed_p ? " (embeddable)" : " (non-embeddable)")
                  : "") .
                 ", scraping HTML.\n"
      if ($verbose > 1);
  }

  # Sometimes the DASH MPD lists formats the get_video_info file does
  # not list, and vice versa!  E.g., format 141.  WTF.
  #
  if (0 && $dashmpd && $verbose) {
    my ($http2, $head2, $body2) = get_url ($dashmpd);
    if (check_http_status ($id, $dashmpd, $http2, 0)) {
      my @reps = split(/<Representation\b/si, $body2);
      shift @reps;
      print STDERR "$progname: $id: DashMPD formats:\n";
      foreach my $rep (@reps) {
        my ($id)   = ($rep =~ m@id=[\'\"](\d+)@si);
        my ($url2) = ($rep =~ m@<BaseURL\b[^<>]*>([^<>]+)@si);
        print STDERR "\t$id\t$url2\n";
      }
    }
  }

  if ($urlmap) {
    $urlmap  = url_unquote ($urlmap);
    $urlmap2 = url_unquote ($urlmap2) if ($urlmap2);

    # Use both url_encoded_fmt_stream_map and adaptive_fmts.
    $urlmap .= ",$urlmap2" if $urlmap2;
    $fmts = youtube_parse_urlmap ($id, $urlmap, $cipher);
  }

  if (! defined($fmts)) {

    # We couldn't get a URL map out of the info URL.
    # Scrape the HTML instead.
    #
    # This still happens for non-embeddable videos, where get_video_info
    # says status=fail with no formats data.  It also happens for RTMPE,
    # but in that case we fail anyway.

    if ($body =~ m/private[+\s]video|video[+\s]is[+\s]private/si) {
      error ("$id: private video");  # scraping won't work.
    }

    my ($err) = ($body =~ m@reason=([^&]+)@s);
    $err = '' unless $err;
    if ($err) {
      $err = url_unquote($err);
      $err =~ s/^"[^\"\n]+"\n//s;
      $err =~ s/\s+/ /gs;
      $err =~ s/^\s+|\s+$//s;
      $err = " (\"$err\")";
    }

    ($title, $urlmap, $urlmap2, $cipher) =
      load_youtube_formats_html ($id, $url, $err);

    # Use both url_encoded_fmt_stream_map and adaptive_fmts.
    $urlmap .= ",$urlmap2" if $urlmap2;
    $fmts = youtube_parse_urlmap ($id, $urlmap, $cipher);
  }

  errorI ("$id: no formats available") unless (defined($fmts));

  $fmts->{title} = $title;
  return $fmts;
}


# Returns a hash of: 
#  [ title: "T",
#    N: [ ...video info... ],
#    M: [ ...video info... ], ... ]
#
sub load_vimeo_formats($$) {
  my ($id, $url) = @_;

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
  if (check_http_status ($id, $url, $http, 0)) {
    if ($body =~ m@(\bhttps?://[^/]+/video/\d+/config\?[^\s\"\'<>]+)@si) {
      $info_url = html_unquote($1);
    } else {
      print STDERR "$progname: $id: no info URL\n" if ($verbose > 1);
    }
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
  #   http://www.vimeo.com/142574658
  #     Only has "progressive" formats, not h264.  Downloads fine though.

  ($http, $head, $body) = get_url ($info_url, $referer);

  my $err = undef;
  if (!check_http_status ($id, $info_url, $http, 0)) {
    ($err) = ($body =~ m@ { "message" : \s* " ( .+? ) " , @six);
    $err = "Private video" if ($err && $err =~ m/privacy setting/si);
    $err = $http . ($err ? ": $err" : "");
  } else {
    $http = '';  # 200
  }

  my ($title)  = ($body =~ m@   "title" : \s* " (.+?) " @six);
  my ($files0) = ($body =~ m@ { "h264"  : \s* \{ ( .+? \} ) \} , @six);
  my ($files1) = ($body =~ m@ { "vp6"   : \s* \{ ( .+? \} ) \} , @six);
  my ($files2) = ($body =~ m@   "progressive" : \s* \[ ( .+? \] ) \} @six);
  my $files    = ($files0 || '') . ($files1 || '') . ($files2 || '');

  # Sometimes we get empty-ish data for "Private Video", but HTTP 200.
  $err = "No video info (Private?)"
    if (!$err && !$title && !$files);

  if ($err) {
    if ($verbose <= 0 && $err =~ m/Private/s) {
      # With --quiet, just silently ignore private videos,
      # for "youtubefeed".
      exit (0);
    }

    error ("$id: $err") if ($http || $err =~ m/Private/s);
    errorI ("$id: $err");
  }

  my %fmts;

  if ($files) {
    errorI ("$id: no title") unless $title;
    $fmts{title} = $title;
    my $i = 0;
    foreach my $f (split (/\},?\s*/, $files)) {
      next unless (length($f) > 50);
      my ($fmt)  = ($f =~ m@^ \" (.+?) ": @six);
         ($fmt)  = ($f =~ m@^ \{ "profile": (\d+) @six) unless $fmt;
      my ($url2) = ($f =~ m@ "url"    : \s* " (.*?) " @six);
      my ($w)    = ($f =~ m@ "width"  : \s*   (\d+)   @six);
      my ($h)    = ($f =~ m@ "height" : \s*   (\d+)   @six);
      errorI ("$id: unparsable video formats")
        unless ($fmt && $url2 && $w && $h);
      print STDERR "$progname: $fmt: ${w}x$h: $url2\n"
        if ($verbose > 2);

      my ($ext) = ($url2 =~ m@^[^?&]+\.([^./?&]+)([?&]|$)@s);
      $ext = 'mp4' unless $ext;
      my $ct = ($ext =~ m/^(flv|webm|3gpp?)$/s ? "video/$ext" :
                $ext =~ m/^(mov)$/s            ? 'video/quicktime' :
                'video/mpeg');

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

  return \%fmts;
}


# Returns a hash of: 
#  [ title: "T",
#    year: "Y",
#    N: [ ...video info... ],
#    M: [ ...video info... ], ... ]
#
sub load_tumblr_formats($$) {
  my ($id, $url) = @_;

  my ($host) = ($url =~ m@^https?://([^/]+)@si);
  my $info_url = "http://api.tumblr.com/v2/blog/$host/posts/video?id=$id";

  my ($http, $head, $body) = get_url ($info_url);
  check_http_status ($id, $url, $http, 1);

  $body =~ s/^.* "posts" : \[ //six;

  my ($title) = ($body =~ m@ "slug" : \s* " (.+?) " @six);
  my ($year)  = ($body =~ m@ "date" : \s* " (\d{4})- @six);

  $title = munge_title (html_unquote ($title || ''));

  my $fmts = {};

  $body =~ s/^.* "player" : \[ //six;

  my $i = 0;
  foreach my $chunk (split (/\},/, $body)) {
    my ($e) = ($chunk =~ m@ "embed_code" : \s* " (.*?) " @six);

    $e =~ s/\\n/\n/gs;
    $e =~ s/ \\[ux] { ([a-z0-9]+)   } / unihex($1) /gsexi;  # \u{XXXXXX}
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



# Return the year at which this video was uploaded.
#
sub get_youtube_year($) {
  my ($id) = @_;

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
  # So, let's scrape the HTML isntead of using the API.
  #
  # (Actually, we don't have a choice now anyway, since they turned off
  # the v2 API in June 2015, and the v3 API requires authentication.)

  # my $data_url = ("http://gdata.youtube.com/feeds/api/videos/$id?v=2" .
  #                 "&fields=published" .
  #                 "&safeSearch=none" .
  #                 "&strict=true");
  my $data_url = "http://www.youtube.com/watch?v=$id";

  my ($http, $head, $body) = get_url ($data_url);
  return undef unless check_http_status ($id, $data_url, $http, 0);

  # my ($year, $mon, $dotm, $hh, $mm, $ss) = 
  #   ($body =~ m@<published>(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)@si);

  my ($year) = ($body =~ m@\bclass="watch-time-text">[^<>]+\b(\d{4})</@s);

  return $year;
}


# Return the year at which this video was uploaded.
#
sub get_vimeo_year($) {
  my ($id) = @_;
  my $data_url = "http://vimeo.com/api/v2/video/$id.xml";
  my ($http, $head, $body) = get_url ($data_url);
  return undef unless check_http_status ($id, $data_url, $http, 0);

  my ($year, $mon, $dotm, $hh, $mm, $ss) = 
    ($body =~ m@<upload_date>(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)@si);
  return $year;
}


# Given a list of available underlying videos, pick the ones we want.
#
sub pick_download_format($$$$$) {
  my ($id, $site, $url, $force_fmt, $fmts) = @_;

  if (defined($force_fmt) && $force_fmt eq 'all') {
    my @all = ();
    foreach my $k (keys %$fmts) {
      next if ($k eq 'title');
      next if ($k eq 'year');
      push @all, $k;
    }
    return sort { $a <=> $b } @all;
  }

  if ($site eq 'vimeo' ||
      $site eq 'tumblr') {
    # On Vimeo and Tumblr, just pick the entry with the largest size
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
      next if ($k eq 'title');
      next if ($k eq 'year');
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
   # ID     video codec      video size        audio codec    bitrate
   #
   0   => { v => 'flv',  w =>  320, h =>  180, a => 'mp3', abr =>  64   },
   5   => { v => 'flv',  w =>  320, h =>  180, a => 'mp3', abr =>  64   },
   6   => { v => 'flv',  w =>  480, h =>  270, a => 'mp3', abr =>  96   },
   13  => { v => '3gp',  w =>  176, h =>  144, a => 'amr', abr =>  13   },
   17  => { v => '3gp',  w =>  176, h =>  144, a => 'aac', abr =>  29   },
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
   151 => { v => 'mp4',  w =>   72, h =>   32, a => undef               },
   160 => { v => 'mp4',  w =>  256, h =>  144, a => undef               },
   167 => { v => 'webm', w =>  640, h =>  360, a => undef               },
   168 => { v => 'webm', w =>  854, h =>  480, a => undef               },
   169 => { v => 'webm', w => 1280, h =>  720, a => undef               },
   170 => { v => 'webm', w => 1920, h => 1080, a => undef               },
   171 => { v => undef,                        a => 'vor', abr => 128   },
   172 => { v => undef,                        a => 'vor', abr => 256   },
   218 => { v => 'webm', w =>  854, h =>  480, a => undef               },
   219 => { v => 'webm', w =>  854, h =>  480, a => undef               },
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
   278 => { v => 'mp4',  w =>  256, h =>  144, a => undef               },
   298 => { v => 'mp4',  w => 1280, h =>  720, a => undef               },
   299 => { v => 'mp4',  w => 1920, h => 1080, a => undef               },
   302 => { v => 'webm', w => 1280, h =>  720, a => undef               },
   303 => { v => 'webm', w => 1920, h => 1080, a => undef               },
#  308 => { v => 'mp4',  w => 2560, h => 1440, a => undef               },
   308 => { v => 'webm', w => 2560, h => 1440, a => undef               },
   313 => { v => 'webm', w => 3840, h => 2160, a => undef               },
   315 => { v => 'webm', w => 3840, h => 2160, a => undef               },
  );
  #
  # The table on http://en.wikipedia.org/wiki/YouTube#Quality_and_codecs
  # disagrees with the above to some extent.  Which is more accurate?
  # (Oh great, they deleted that table from Wikipedia. Lovely.)
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
  #   http://www.youtube.com/watch?v=wjzyv2Q_hdM
  #   5-Aug-2011: 38=flv/1080p but 45=webm/720p.
  #   6-Aug-2011: 38 no longer offered.
  #
  #   http://www.youtube.com/watch?v=ms1C5WeSocY
  #   6-Aug-2011: embedding disabled, but get_video_info works.
  #
  #   http://www.youtube.com/watch?v=g40K0dFi9Bo
  #   10-Sep-2011: 3D, fmts 82 and 84.
  #
  #   http://www.youtube.com/watch?v=KZaVq1tFC9I
  #   14-Nov-2011: 3D, fmts 100 and 102.  This one has 2D images in most
  #   formats but left/right images in the 3D formats.
  #
  #   http://www.youtube.com/watch?v=SlbpRviBVXA
  #   15-Nov-2011: 3D, fmts 46, 83, 85, 101.  This one has left/right images
  #   in all of the formats, even the 2D formats.
  #
  #   http://www.youtube.com/watch?v=711bZ_pLusQ
  #   30-May-2012: First sighting of fmt 36, 3gpp/240p.
  #
  #   http://www.youtube.com/watch?v=0yyorhl6IjM
  #   30-May-2013: Here's one that's more than an hour long.
  #
  #   http://www.youtube.com/watch?v=pc4ANivCCgs
  #   15-Nov-2013: First sighting of formats 59 and 78.
  #
  #   http://www.youtube.com/watch?v=WQzVhOZnku8
  #   3-Sep-2014: First sighting of a 24/7 realtime stream.
  #
  #   http://www.youtube.com/watch?v=gTIK2XawLDA
  #   22-Jan-2015: DNA Lounge 24/7 live stream, 640x360.
  #
  #   http://www.youtube.com/watch?v=hHKJ5eE7I1k
  #   22-Jan-2015: 2K video. Formats 36, 136, 137, 138.
  #
  #   http://www.youtube.com/watch?v=udAL48P5NJU
  #   22-Jan-2015: 4K video. Formats 36, 136, 137, 138, 266, 313.
  #
  #   http://www.youtube.com/watch?v=OEhRucEVzH8
  #   20-Feb-2015: best formats 18 (640 x 360) and 135 (854 x 480)
  #   First sighting of a video where we must mux to get the best
  #   non-HD version.
  #
  #   http://www.youtube.com/watch?v=Ol61WOSzLF8
  #   10-Mar-2015: formerly RTMPE but 14-Apr-2015 no longer
  #
  #   http://www.youtube.com/watch?v=1ltcDfZMA3U  Maps
  #   29-Mar-2015: formerly playable in US region, but no longer
  #
  #   http://www.youtube.com/watch?v=ttqMGYHhFFA  Metric
  #   29-Mar-2015: Formerly enciphered, but no longer
  #
  #   http://www.youtube.com/watch?v=7wL9NUZRZ4I  Bowie
  #   29-Mar-2015: Formerly enciphered and content warning; no longer CW.
  #
  #   http://www.youtube.com/watch?v=07FYdnEawAQ Timberlake
  #   29-Mar-2015: enciphered and "content warning" (HTML scraping fails)
  #
  #   http://youtube.com/watch?v=HtVdAasjOgU
  #   29-Mar-2015: content warning, but non-enciphered
  #
  #   http://www.youtube.com/watch?v=__2ABJjxzNo
  #   29-Mar-2015: has url_encoded_fmt_stream_map but not adaptive_fmts
  #
  #   http://www.youtube.com/watch?v=lqQg6PlCWgI
  #   29-Mar-2015: finite-length archive of a formerly livestreamed video.
  #   We currently can't download this, but it's doable.
  #   See dna/backstage/src/slideshow/slideshow-youtube-frame.pl
  #
  #   Enciphered:
  #   http://www.youtube.com/watch?v=ktoaj1IpTbw  Chvrches
  #   http://www.youtube.com/watch?v=28Vu8c9fDG4  Emika
  #   http://www.youtube.com/watch?v=_mDxcDjg9P4  Vampire Weekend
  #   http://www.youtube.com/watch?v=8UVNT4wvIGY  Gotye
  #   http://www.youtube.com/watch?v=OhhOU5FUPBE  Black Sabbath
  #   http://www.youtube.com/watch?v=UxxajLWwzqY  Icona Pop
  #
  #   http://www.youtube.com/watch?v=g_uoH6hJilc
  #   28-Mar-2015: enciphered Vevo (Years & Years) on which CTF was failing
  #
  #   http://www.youtube.com/watch?v=ccyE1Kz8AgM
  #   28-Mar-2015: not viewable in US (US is not on the include list)
  #
  #   http://www.youtube.com/watch?v=ccyE1Kz8AgM
  #   28-Mar-2015: blocked in US (US is on the exclude list)
  #
  #   http://www.youtube.com/watch?v=GjxOqc5hhqA
  #   28-Mar-2015: says "please sign in", but when signed in, it's private
  #
  #   http://www.youtube.com/watch?v=UlS_Rnb5WM4
  #   28-Mar-2015: non-embeddable (Pogo)
  #
  #   http://www.youtube.com/watch?v=JYEfJhkPK7o
  #   14-Apr-2015: RTMPE DRM
  #   get_video_info fails with "This video contains content from Mosfilm,
  #   who has blocked it from display on this website.  Watch on Youtube."
  #   There's a generic rtmpe: URL in "conn" and a bunch of options in
  #   "stream", but I don't know how to put those together into an
  #   invocation of "rtmpdump" that does anything at all.
  #
  #   http://www.youtube.com/watch?v=UXMG102kSvk
  #   17-Aug-2015: WebM higher rez than MP4:
  #   299 (1920 x 1080 mp4 v/o)
  #   308 (2560 x 1440 webm v/o)  <-- webm, not mp4
  #   315 (3840 x 2160 webm v/o)
  #
  #   http://www.youtube.com/watch?v=dC_nFgJAcuQ
  #   2-Dec-2015: First sighting of 5.1 stereo formats 256 and 258.


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
                                    "???") .
                                   ($c ? " $c" : '') .
                                   ($w && $h && $b ? '' :
                                    $w ? ' v/o' : ' a/o'));

    error ("W and H flipped: $id") if ($w && $h && $w < $h);

    # Ignore 3d video or other weirdo vcodecs.
    next if ($v && !($v =~ m/^(mp4|flv|3gp|webm)$/));

    # WebM must always go along with Vorbis audio.  ffmpeg can't mux
    # MP4 video and Vorbis audio together, or WebM video and MP3 audio.
    # But sometimes the highest bandwidth streams are MP4 + Vorbis,
    # or WebM + MP3.
    #
    # So you know what, fuck it, let's just always ignore both WebM
    # and Vorbis.

    next if ($a && !$v && $a =~ m/^(vor)$/);
    next if (!$a && $v && $v =~ m/^(webm)$/);

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

      my $aa = $A->{h} || 0;			# Prefer taller video.
      my $bb = $B->{h} || 0;
      return ($bb - $aa) unless ($aa == $bb);

      $aa = (($A->{v} || '') eq 'mp4');		# Prefer MP4 over WebM.
      $bb = (($B->{v} || '') eq 'mp4');
      return ($bb - $aa) unless ($aa == $bb);

      $aa = $A->{c} || 0;			# Prefer 5.1 over stereo.
      $bb = $B->{c} || 0;
      return ($bb - $aa) unless ($aa == $bb);

      $aa = $A->{abr} || 0;			# Prefer higher audio rate.
      $bb = $B->{abr} || 0;
      return ($bb - $aa) unless ($aa == $bb);

      $aa = (($A->{a} || '') eq 'aac');		# Prefer AAC over MP3.
      $bb = (($B->{a} || '') eq 'aac');
      return ($bb - $aa) unless ($aa == $bb);

      $aa = (($A->{a} || '') eq 'mp3');		# Prefer MP3 over Vorbis.
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
    foreach my $target (@pref_ao) {
      if ($fmts->{$target}) {
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
    if ($mfmt &&
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
    # a warning, then fall back to a lower resolution stream.
    #
    if ($vfmt && $afmt && !which ("ffmpeg")) {
      print STDERR "$progname: WARNING: $id: \"ffmpeg\" not installed.\n";
      print STDERR "$progname:          $id: downloading lower resolution.\n";
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
      next if ($k eq 'title');
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
      next if ($k eq 'title');
      print STDERR sprintf("%s:   %3d (%s)\n",
                           $progname, $k,
                           $known_formats{$k}->{desc} || '?');
    }
  }

  if ($vfmt && $afmt) {
    if ($verbose > 1) {
      my $d1 = $known_formats{$vfmt}->{desc};
      my $d2 = $known_formats{$afmt}->{desc};
      foreach ($d1, $d2) { s@ [av]/?o$@@si; }
      print STDERR "$progname: $id: picked $vfmt + $afmt ($d1 + $d2)\n";
    }
    return ($vfmt, $afmt);
  } else {
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

  return $title unless defined($title);

  sub unihex($) { 
    my ($c) = @_;
    $c = hex($c);
    my $s = chr($c);

    # If this is a single-byte non-ASCII character, chr() created a
    # single-byte non-Unicode string.  Assume that byte is Latin1 and
    # expand it to the corresponding unicode character.
    #
    # Test cases:
    #   http://www.vimeo.com/82503761			é  as \u00e9\u00a0
    #   http://www.vimeo.com/123397581			û– as \u00fb\u2013
    #   http://www.youtube.com/watch?v=z9ScJBmEdQw	ä  as UTF8 (2 bytes)
    #   http://www.youtube.com/watch?v=eAXmgId3NTQ	ø  as UTF8 (2 bytes)
    #   http://www.youtube.com/watch?v=FszEaxrHGTs	∆  as UTF8 (3 bytes)
    #   http://www.youtube.com/watch?v=4ViwSeuWVfE	JP as UTF8 (3 bytes)
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
  $title =~ s/ \\[ux] { ([a-z0-9]+)   } / unihex($1) /gsexi;  # \u{XXXXXX}
  $title =~ s/ \\[ux]   ([a-z0-9]{4})   / unihex($1) /gsexi;  # \uXXXX

  $title =~ s/[\x{2012}-\x{2013}]+/-/gs;	# various dashes
  $title =~ s/[\x{2014}-\x{2015}]+/--/gs;	# various long dashes
  $title =~ s/\x{2018}+/`/gs;			# backquote
  $title =~ s/\x{2019}+/'/gs;			# quote
  $title =~ s/[\x{201c}\x{201d}]+/"/gs;		# ldquo, rdquo
  $title =~ s/`/'/gs;

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
  $title =~ s/ on Vimeo\s*$//si;
  $title =~ s/Broadcast Yourself\.?$//si;

  $title =~ s/\b ( ( (in \s*)? 
                     (
                       HD | TV | HDTV | HQ | 720\s*p? | 1080\s*p? | 4K |
                       High [-\s]* Qual (ity)? 
                     ) |
                     FM('s)? |
                     EP s? (?>[\s\.\#]*) (?!\d+) |   # allow "episode" usage
                     MV | performance |
                     SXSW ( \s* Music )? ( \s* \d{4} )? |
                     Showcasing \s Artist |
                     Presents |
                     (DVD|CD)? \s+ (out \s+ now | on \s+ (iTunes|Amazon)) |
                     fan \s* made |
                     ( FULL|COMPLETE ) \s+ ( set|concert|album ) |
                     FREE \s+ ( download|D\s*[[:punct:]-]\s*L )
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
          teaser | trailer 
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

  ($title, $junk) = ($1, $2)			# TITLE (JUNK)
    if ($title =~ m/^(.*)\s+$obrack+ (.*) $cbrack+ $/six);

  ($title, $junk) = ($1, "$3 $junk")  # TITLE (Dir. by D) .*
    if ($title =~ m/^ ( .+? )
                      ($obrack+|\s)\s* ((Dir|Prod)\. .*)$/six);


  ($track, $artist) = ($1, $2)			# TRACK performed by ARTIST
    if (!$artist &&				# TRACK by ARTIST
        $title =~ m/^ ( .+? ) \b
                      (?: performed \s+ )? by \b ( .+ )$/six);

  ($artist, $track) = ($1, $2)			# ARTIST performing TRACK
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

  ($track, $artist) = ($1, $2)				# "TRACK" ARTIST
    if (!$artist &&
        $title =~ m/^ \" ( .+? ) \" [,\s]+ ( .+ )$/six);

  ($artist, $track, $junk) = ($1, $2, "$3 $junk")	# ARTIST "TRACK" JUNK
    if (!$artist &&
        $title =~ m/^ ( .+? ) [,\s]+ \" ( .+ ) \" ( .*? ) $/six);


  ($track, $artist) = ($1, $2)				# 'TRACK' ARTIST
    if (!$artist &&
        $title =~ m/^ \' ( .+? ) \' [,\s]+ ( .+ )$/six);

  ($artist, $track, $junk) = ($1, $2, "$3 $junk")	# ARTIST 'TRACK' JUNK
    if (!$artist &&
        $title =~ m/^ ( .+? ) [,\s]+ \' ( .+ ) \' ( .*? ) $/six);


  ($artist, $track) = ($1, $2)				# ARTIST -- TRACK
    if (!$artist &&
        $title =~ m/^ ( .+? ) \s* --+ \s* ( .+ )$/six);

  ($artist, $track) = ($1, $2)				# ARTIST: TRACK
    if (!$artist &&
        $title =~ m/^ ( .+? ) \s* :+  \s* ( .+ )$/six);


  ($artist, $track) = ($1, $2)				# ARTIST-- TRACK
    if (!$artist &&
        $title =~ m/^ ( .+? )     --+ \s* ( .+ )$/six);

  ($artist, $track) = ($1, $2)				# ARTIST - TRACK
    if (!$artist &&
        $title =~ m/^ ( .+? ) \s+ -   \s+ ( .+ )$/six);

  ($artist, $track) = ($1, $2)				# ARTIST- TRACK
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
      .'BT|INXS|THX|SNL|CTRL|'
        
      .'POB|JPL|LNX|' # are these DJs? abbreviations?
        
      .'YKWYR|MFN|TV|ICHRU|AAA|OK|MJ|'   # TRACKS
      .'I\s?L\s?U|TKO|SWAG|'
      .'LAX|ADHD|BTR'
    ;

    $s =~ s/\b([[:upper:]])([[:upper:]\d]+)\b/$1\L$2/gsi  # Capitalize,
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

  return $title || "Untitled";
}



# Does any version of the file exist with the usual video suffixes?
# Returns the one that exists.
#
sub file_exists_with_suffix($) {
  my ($f) = @_;
  foreach my $ext (@video_extensions) {
    my $ff = "$f.$ext";
    # No, don't do this.
    # utf8::encode($ff);   # Unpack wide chars into multi-byte UTF-8.
    return ($ff) if -f ($ff);
  }
  return undef;
}


# Generates HTML output that provides a link for direct downloading of
# the highest-resolution underlying video.  The HTML also lists the
# video dimensions and file size, if possible.
#
sub cgi_output($$$@) {
  my ($id, $title, $orig_url, @targets) = @_;

  my $video  = $targets[0];
  my $audio  = $targets[1];
  my $premux = $targets[2];

  my ($w, $h, $size) = video_url_size ($id,
                                       $video->{url},
                                       $video->{content_type});
  $size = -1 unless defined($size);

  my ($w3, $h3, $size3) = video_url_size ($id,
                                          $premux->{url},
                                          $premux->{content_type})
    if ($premux);
  $size3 = -1 unless defined($size3);

  my $ss = ($size <= 0 ? '<SPAN CLASS="err">size unknown</SPAN>' :
            fmt_size($size));
  my $wh = ($w && $h ? "$w &times; $h" : "resolution unknown");
  $wh = '<SPAN CLASS="err">' . $wh . '</SPAN>'
    if (($w || 0) < 1024);
  $ss = "$wh, $ss";

  my $ss3 = ($size3 <= 0 ? '<SPAN CLASS="err">size unknown</SPAN>' :
             fmt_size($size3))
    if ($premux);
  my $wh3 = ($w3 && $h3 ? "$w3 &times; $h3" : "resolution unknown");
  $wh3 = '<SPAN CLASS="err">' . $wh3 . '</SPAN>'
    if (($w3 || 0) < 1024);
  $ss3 = "$wh3, $ss3"
    if ($wh3 && $ss3);

  my $file = $video->{file};
  my $url  = $video->{url};
  my $ct   = $video->{content_type};
  my $url2 = $audio->{url} if ($audio);
  my $ct2  = $audio->{content_type} if ($audio);
  my $url3 = $premux->{url} if ($premux);
  my $ct3  = $premux->{content_type} if ($premux);


  # I had hoped that transforming
  #
  #   http://v5.lscache2.googlevideo.com/videoplayback?ip=....
  #
  # into
  #
  #   http://v5.lscache2.googlevideo.com/videoplayback/Video+Title.mp4?ip=....
  #
  # would trick Safari into downloading the file with a sensible file name.
  # Normally Safari picks the target file name for a download from the final
  # component of the URL.  Unfortunately that doesn't work in this case,
  # because the "videoplayback" URL is sending
  #
  #   Content-Disposition: attachment; filename="video.mp4"
  #
  # which overrides my trickery, and always downloads it as "video.mp4"
  # regardless of what the final component in the path is.
  #
  # However, if you do "Save Link As..." on this link, the default file
  # name is sensible!  So it takes two clicks to download it instead of
  # one.  Oh well, I can live with that.
  #
  # UPDATE: If we do "proxy=" instead of "redir=", then all the data moves
  # through this CGI, and it will insert a proper Content-Disposition header.
  # However, if the CGI is not hosted on localhost, then this will first
  # download the entire video to your web host, then download it again to
  # your local machine.
  #
  # Sadly, Vimeo is now doing user-agent sniffing on the "moogaloop/play/"
  # URLs, so this is now the *only* way to make it work: if you try to
  # download one of those URLs with a Safari/Firefox user-agent, you get
  # a "500 Server Error" back.
  #
  # Also, "proxy=" is the only way to make muxing work, and thus the only
  # way to download HD videos from Youtube.
  #
  my $proxy_p = 1;
  utf8::encode ($file);   # Unpack wide chars into multi-byte UTF-8.

  $url = (url_quote($url) .		# video URL
          ($url2
           ? '|' . url_quote($url2)	# audio URL
           : ''));
  $ct .= "|$ct2" if $ct2;

  $url3 = url_quote($url3) if $url3;	# premuxed URL


  my $muxed_file = $file;
  $muxed_file =~ s@\.(audio-only|video-only)\.@.@gs;

  $url = ($ENV{SCRIPT_NAME} . 
          '/' . url_quote($muxed_file) .
          '?src=' . url_quote($orig_url) .
          '&' . ($proxy_p? 'proxy' : 'redir') .
          '=' . $url .
          '&ct=' . $ct
         );
  $url3 = ($ENV{SCRIPT_NAME} . 
          '/' . url_quote($muxed_file) .
          '?src=' . url_quote($orig_url) .
          '&' . ($proxy_p? 'proxy' : 'redir') .
          '=' . $url3 .
          '&ct=' . $ct3
         )
    if ($url3);

  $url  = html_quote ($url);
  $url3 = html_quote ($url3) if ($url3);
  $title = html_quote ($title);


  # New HTML5 feature: <A DOWNLOAD=...> seems to be a client-side way of
  # doing the same thing that "Content-Disposition: attachment; filename="
  # does.  Unfortunately, even with this, Safari still opens the .MP4 file
  # after downloading instead of just saving it.

  my $body = $html_head . "\n";
  $body =~ s@(<TITLE>)[^<>]*@$1Download "$title"@gsi;
  $body .= "  Save Link As: <B>$title</B><BR>";
  $body .= (" &nbsp; &nbsp; &nbsp; &bull; " .
            "<A HREF=\"$url\"\n    DOWNLOAD=\"$title\">$ss</A>");
  $body .= ("<BR>" .
            " &nbsp; &nbsp; &nbsp; &bull; " .
            "<A HREF=\"$url3\"\n    DOWNLOAD=\"$title\">$ss3</A>")
    if ($url3);

  $body .= "\n" . $html_tail;

  binmode (STDOUT, ':raw');
  print STDOUT ("Content-Type: text/html; charset=UTF-8\n" .
                "\n" .
                $body);
}


# There are so many ways to specify URLs of videos... Turn them all into
# something sane and parsable.

sub canonical_url($) {
  my ($url) = @_;

  # Forgive pinheaddery.
  $url =~ s@&amp;@&@gs;
  $url =~ s@&amp;@&@gs;

  # Add missing "http:"
  $url = "http://$url" unless ($url =~ m@^https?://@si);

  # Rewrite youtu.be URL shortener.
  $url =~ s@^https?://([a-z]+\.)?youtu\.be/@http://youtube.com/v/@si;

  # Rewrite Vimeo URLs so that we get a page with the proper video title:
  # "/...#NNNNN" => "/NNNNN"
  $url =~ s@^(https?://([a-z]+\.)?vimeo\.com/)[^\d].*\#(\d+)$@$1$3@s;

  $url =~ s@^https:@http:@s;	# No https.

  my ($id, $site, $playlist_p);

  # Youtube /view_play_list?p= or /p/ URLs. 
  if ($url =~ m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/
                (?: view_play_list\?p= |
                    p/ |
                    embed/p/ |
                    playlist\?list=(?:PL)? |
                    watch\?list=(?:PL)? |
                    embed/videoseries\?list=(?:PL)?
                )
                ([^<>?&,]+) ($|&) @sx) {
    ($site, $id) = ($1, $2);
    $url = "http://www.$site.com/view_play_list?p=$id";
    $playlist_p = 1;

  # Youtube "/verify_age" URLs.
  } elsif ($url =~ 
           m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/+
	     .* next_url=([^&]+)@sx ||
           $url =~ m@^https?://(?:[a-z]+\.)?google\.com/
                     .* service = (youtube)
                     .* continue = ( http%3A [^?&]+)@sx ||
           $url =~ m@^https?://(?:[a-z]+\.)?google\.com/
                     .* service = (youtube)
                     .* next = ( [^?&]+)@sx
          ) {
    $site = $1;
    $url = url_unquote($2);
    if ($url =~ m@&next=([^&]+)@s) {
      $url = url_unquote($1);
      $url =~ s@&.*$@@s;
    }
    $url = "http://www.$site.com$url" if ($url =~ m@^/@s);

  # Youtube /watch/?v= or /watch#!v= or /v/ URLs. 
  } elsif ($url =~ m@^https?:// (?:[a-z]+\.)?
                     (youtube) (?:-nocookie)? (?:\.googleapis)? \.com/+
                     (?: (?: watch/? )? (?: \? | \#! ) v= |
                         v/ |
                         embed/ |
                         .*? &v= |
                         [^/\#?&]+ \#p(?: /[a-zA-Z\d] )* /
                     )
                     ([^<>?&,\'\"]+) ($|[?&]) @sx) {
    ($site, $id) = ($1, $2);
    $url = "http://www.$site.com/watch?v=$id";

  # Youtube "/user" and "/profile" URLs.
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(youtube) (?:-nocookie)? \.com/
                     (?:user|profile).*\#.*/([^&/]+)@sx) {
    $site = $1;
    $id = url_unquote($2);
    $url = "http://www.$site.com/watch?v=$id";
    error ("unparsable user next_url: $url") unless $id;

  # Vimeo /NNNNNN URLs
  # and player.vimeo.com/video/NNNNNN
  # and vimeo.com/m/NNNNNN
  } elsif ($url =~ 
           m@^https?://(?:[a-z]+\.)?(vimeo)\.com/(?:video/|m/)?(\d+)@s) {
    ($site, $id) = ($1, $2);
    $url = "http://www.$site.com/$id";

  # Vimeo /videos/NNNNNN URLs.
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(vimeo)\.com/.*/videos/(\d+)@s) {
    ($site, $id) = ($1, $2);
    $url = "http://www.$site.com/$id";

  # Vimeo /channels/name/NNNNNN URLs.
  # Vimeo /ondemand/name/NNNNNN URLs.
  } elsif ($url =~ 
           m@^https?://(?:[a-z]+\.)?(vimeo)\.com/[^/]+/[^/]+/(\d+)@s) {
    ($site, $id) = ($1, $2);
    $url = "http://www.$site.com/$id";

  # Vimeo /moogaloop.swf?clip_id=NNNNN
  } elsif ($url =~ m@^https?://(?:[a-z]+\.)?(vimeo)\.com/.*clip_id=(\d+)@s) {
    ($site, $id) = ($1, $2);
    $url = "http://www.$site.com/$id";

  # Tumblr /video/UUU/NNNNN
  } elsif ($url =~
           m@^https?://[-_a-z]+\.(tumblr)\.com/video/([^/]+)/(\d{8,})/@si) {
    my $user;
    ($site, $user, $id) = ($1, $2, $3);
    $site = lc($site);
    $url = "http://$user.$site.com/post/$id";

  # Tumblr /post/NNNNN
  } elsif ($url =~ m@^https?://([-_a-z]+)\.(tumblr)\.com/.*?/(\d{8,})/@si) {
    my $user;
    ($user, $site, $id) = ($1, $2, $3);
    $site = lc($site);
    $url = "http://$user.$site.com/post/$id";

  } else {
    error ("unparsable URL: $url");
  }

  return ($url, $id, $site);
}


# Having downloaded a video file and an audio file, combine them and delete
# the two originals.
#
sub mux_downloaded_files($$$$$$) {
  my ($id, $url, $title, $v1, $v2, $muxed_file) = @_;

  my $video_file = $v1->{file};
  my $audio_file = $v2->{file};

  if (! defined($muxed_file)) {
    $muxed_file = $video_file;
    $muxed_file =~ s@\.(audio-only|video-only)\.@.@gs;
    $muxed_file =~ s@ [^\s\[\]]+(\].)@$1@gs;
  }

  error ("$id: mismunged filename $muxed_file")
    if ($muxed_file eq $audio_file || $muxed_file eq $video_file);
  error ("$id: exists: $muxed_file") if (-f $muxed_file);

  my @cmd = ('ffmpeg',
             # "-hide_banner", # not present in 0.6.5
             # "-loglevel", "panic",

             '-i', $video_file,
             '-i', $audio_file,
             '-vcodec', 'copy',	# no re-encoding
             '-acodec', 'copy',
             '-map', '0:v:0',	# from file 0, video track 0
             '-map', '1:a:0',	# from file 1, audio track 0
             '-shortest',	# they should be the same length already
             $muxed_file);
  if ($verbose == 1) {
    print STDERR "$progname: $id: combining audio and video...\n";
  } elsif ($verbose > 1) {
    print STDERR "$progname: $id: exec: '" . join("' '", @cmd) . "'\n";
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
      local $/ = undef;  # read entire file
      while (<$err>) {
        $result .= $_;
      }

      waitpid ($pid, 0);
      my $exit_value  = $? >> 8;
      my $signal_num  = $? & 127;
      my $dumped_core = $? & 128;

      if ($verbose > 2) {
        $_ = $result;
        s/^/$cmd[0]: /gm;
        print STDERR "$_\n";
      }

      $err = undef;
      $err = "$id: $cmd[0]: core dumped!" if ($dumped_core);
      $err = "$id: $cmd[0]: signal $signal_num!" if ($signal_num);
      $err = "$id: $cmd[0]: exited with $exit_value!" if ($exit_value); 
    }

    if ($err) {
      unlink ($muxed_file);  # It's not a download, and it's broken.
      if ($verbose < 2) {
        my @L = split(/(?:\r?\n)+/, $result);
        $result = join ("\n", @L[-5 .. -1])     # only last 5 lines
          if (@L > 5);
      }
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
  my $diff = $s1 - $s3;
  if ($s1 > (1024 * 1024) &&	# size > 1M
      $diff > 1024 * 200 &&	# diff > 200K
      $diff > $s1 * 0.2) {	# diff > 2%
    my $s1b = fmt_size ($s1);
    my $s3b = fmt_size ($s3);
    unlink ($audio_file, $video_file, $muxed_file);
    error ("$id: $cmd[0] wrote a short file! Got $s3b, expected $s1b" .
           " ($s1 - $s3 = $diff)");
  }

  unlink ($audio_file, $video_file);

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



sub content_type_ext($) {
  my ($ct) = @_;
  if    ($ct =~ m@/(x-)?flv$@si)  { return 'flv';  }
  elsif ($ct =~ m@/(x-)?webm$@si) { return 'webm'; }
  elsif ($ct =~ m@/(x-)?3gpp$@si) { return '3gpp'; }
  elsif ($ct =~ m@/quicktime$@si) { return 'mov';  }
  elsif ($ct =~ m@^audio/mp4$@si) { return 'm4a';  }
  else                            { return 'mp4';  }
}

sub download_video_url($$$$$$$$) {
  my ($url, $title, $prefix, $size_p, $list_p,
      $progress_p, $cgi_p, $force_fmt) = @_;

  $error_whiteboard = '';	# reset per-URL diagnostics
  $progress_ticks = 0;		# reset progress-bar counters
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
    return download_youtube_playlist ($id, $url, $title, $prefix, $size_p,
                                      $list_p, $progress_p, $cgi_p,
                                      $force_fmt);
  }

  # Handle --list for playlists.
  #
  if ($list_p) {
    if ($list_p > 1) {
      my $t2 = ($prefix ? "$prefix $title" : $title);
      print STDOUT "$id\t$t2\n";
    } else {
      print STDOUT "http://www.$site.com/watch?v=$id\n";
    }
    return;
  }


  my $suf = (" [" . $id .
             ($force_fmt && $force_fmt ne 'mux' ? " $force_fmt" : "") .
             "]");

  if (! ($size_p || $list_p)) {

    # If we're writing with --suffix, we can check for an existing file before
    # knowing the title of the video.  Check for a file with "[this-ID]" in it.
    # (The quoting rules of perl's "glob" function are ridiculous and
    # confusing, so let's do it the hard way instead.)
    #
    opendir (my $dir, '.') || error ("readdir: $!");
    foreach my $f (readdir ($dir)) {
      if ($f =~ m/\Q$suf\E/s) {
        exit (1) if ($verbose <= 0); # Skip silently if --quiet.
        error ("$id: exists: $f");
      }
    }
    closedir $dir;

    # If we already have a --title, we can check for the existence of the file
    # before hitting the network.  Otherwise, we need to download the video
    # info to find out the title and thus the file name.
    #
    if (defined($title)) {
      my $t2 = ($prefix ? "$prefix $title" : $title);
      my $o = (file_exists_with_suffix ("$t2") ||
               file_exists_with_suffix ("$t2$suf") ||
               file_exists_with_suffix ("$title") ||
               file_exists_with_suffix ("$title$suf"));
      if ($o) {
        exit (1) if ($verbose <= 0); # Skip silently if --quiet.
        error ("$id: exists: $o");
      }
    }
  }


  # Videos can come in multiple resolutions, and sometimes with audio and
  # video in separate URLs. Get the list of all possible downloadable video
  # formats.
  #
  my $fmts = ($site eq 'youtube' ? load_youtube_formats ($id, $url) :
              $site eq 'vimeo'   ? load_vimeo_formats ($id, $url) :
              $site eq 'tumblr'  ? load_tumblr_formats ($id, $url) :
              error ("$id: unknown site: $site"));

  # Set the title unless it was specified on the command line with --title.
  #
  if (! defined($title)) {
    $title = munge_title ($fmts->{title});

    # Add the year to the title unless there's a year there already.
    #
    if ($title !~ m@ \(\d{4}\)@si) {  # skip if already contains " (NNNN)"
      my $year = ($fmts->{year}      ? $fmts->{year}          :
                  $site eq 'youtube' ? get_youtube_year ($id) :
                  $site eq 'vimeo'   ? get_vimeo_year ($id)   : undef);
      if ($year && 
          $year  != (localtime())[5]+1900 &&   # Omit this year
          $title !~ m@\b$year\b@s) {		 # Already in the title
        $title .= " ($year)";
      }
    }

    # Now that we've hit the network and determined the real title, we can
    # check for existing files on disk.
    #
    if (! ($size_p || $list_p)) {
      my $t2 = ($prefix ? "$prefix $title" : $title);
      my $o = (file_exists_with_suffix ("$t2") ||
               file_exists_with_suffix ("$title") ||
               file_exists_with_suffix ("$title") ||
               file_exists_with_suffix ("$title$suf"));
      if ($o) {
        exit (1) if ($verbose <= 0); # Skip silently if --quiet.
        error ("$id: exists: $o");
      }
    }
  }


  # Now that we have the video info, decide what to download.
  # If we're doing --fmt all, this is all of them.
  # Otherwise, it's either one URL or two (audio + video mux).
  #
  my @targets = pick_download_format ($id, $site, $url, $force_fmt, $fmts);
  my @pair = (@targets == 2 && $force_fmt ne 'all' ? @targets : ());

  if ($cgi_p && @pair) {
    # If we're producing CGI output, and we wanted and requested a muxed
    # file, also add the non-muxed file onto the end of the list, to give
    # the user an option of both formats.
    my @t2 = pick_download_format ($id, $site, $url, undef, $fmts);
    push @targets, @t2 if @t2;
  }


  if ($size_p && @pair) {
    # With --size, we only need to examine the first pair of the mux.
    @targets = ($pair[0]);
    @pair = ();
  }

  my @cgi_args;

  $append_suffix_p = 1
    if (!$size_p && defined($force_fmt) && $force_fmt eq 'all');

  foreach my $target (@targets) {
    my $fmt = $fmts->{$target};
    my $ct   = $fmt->{content_type};
    my $w    = $fmt->{width};
    my $h    = $fmt->{height};
    my $abr  = $fmt->{abr};
    my $size = $fmt->{size};
    my $url2 = $fmt->{url};

    if ($size_p) {
      if (! (($w && $h) || $abr)) {
        ($w, $h, $size, $abr) = video_url_size ($id, $url2, $ct);
      }

      my $ii = $id . (@targets == 1 ? '' : ":$target");
      my $ss = fmt_size ($size);
      my $wh = ($w && $h
                ? "${w} x ${h}"
                : "$abr  ");
      my $t2 = ($prefix ? "$prefix $title" : $title);
      print STDOUT "$ii\t$wh\t$ss\t$t2\n";

    } else {

      $suf = ($append_suffix_p
              ? (" [" . $id .
                 (@targets == 1 ? '' : " $target") .
                 "]")
              : (@pair
                 ? ($target == $pair[0] ? '.video-only' : '.audio-only')
                 : ''));

      my $file = ($prefix ? "$prefix $title" : $title) . $suf;

      $file .= '.' . content_type_ext($ct);
      $fmt->{file} = $file;

      if ($cgi_p) {
        push @cgi_args, $fmt;
        next;
      }

      if (-f $file) {
        exit (1) if ($verbose <= 0); # Skip silently if --quiet.
        error ("$id: exists: $file");
      }

      print STDERR "$progname: reading \"$file\"\n" if ($verbose > 0);

      my $start_time = time();
      my ($http, $head, $body) = get_url ($url2, undef, $file,
                                          undef, $progress_p);
      my $download_time = time() - $start_time;

      check_http_status ($id, $url, $http, 2);  # internal error if still 403

      if (! -s $file) {
        unlink ($file);
        error ("$file: failed: $url");
      }

      write_file_metadata_url ($file, $id, $url)
        # The metadata tags seem to confuse ffmpeg.
        if (!@pair && !$ENV{HTTP_HOST});

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
    }
  }

  if ($cgi_p) {
    cgi_output ($id, $title, $url, @cgi_args);

  } elsif (@pair) {
    mux_downloaded_files ($id, $url, $title, 
                          $fmts->{$pair[0]},
                          $fmts->{$pair[1]},
                          undef);
  }

}


sub download_youtube_playlist($$$$$$$$$) {
  my ($id, $url, $title, $prefix, $size_p, $list_p, $progress_p, $cgi_p,
      $force_fmt) = @_;

  my @playlist = ();

  my $start = 0;

  my ($http, $head, $body) = get_url ($url);
  check_http_status ($id, $url, $http, 1);

  ($title) = ($body =~ m@<title>\s*([^<>]+?)\s*</title>@si)
    unless $title;
  $title = munge_title($title);
  $title = 'Untitled Playlist' unless $title;

  ($body =~ s/^.*?<div \s+ id="pl-video-list"//six) ||
    errorI ("unparsable playlist HTML: $url");

  my $i = 0;
  $body =~ s@<A \b (.*?) > \s* ([^<>]*?) \s* </A> @{
    my ($href, $t2) = ($1, $2);
    (undef, $href) = ($href =~ m% \b href \s* = \s* (["'])(.*?)\1%six);
    if ($href && $t2) {
      $href = html_unquote($href);
      if ($href =~ m%[?&]v=([^?&]+)%si) {
        $href = $1;
        $t2 = munge_title (html_unquote ($t2));
        $t2 = sprintf("%s: %02d: %s", $title, ++$i, $t2);
        $href = 'http://www.youtube.com/watch?v=' . $href;
        push \@playlist, [ $t2, $href ];
      }
    }
    "";
  }@gsexi;

  errorI ("$id: no playlist entries?") unless @playlist;

  # With "--size", only get the size of the first video.
  # With "--size --size", get them all.
  if ($size_p == 1) {
    @playlist = ( $playlist[0] );
  }

  # Scraping the HTML only gives us the first hundred videos if the
  # playlist has more than that.  I don't yet know how to get the
  # rest.  The "Show More" button at the bottom does AJAX bullshit.
  #
  my $max = 100;
  print STDERR "$progname: WARNING: $id: " .
               "only able to download the first $max videos!\n"
    if (@playlist == $max);

  print STDERR "$progname: playlist \"$title\" (" . scalar (@playlist) .
                 " entries)\n"
    if ($verbose > 1);

  foreach my $P (@playlist) {
    my ($t2, $u2) = @$P;
    eval {
      $noerror = 1;
      download_video_url ($u2, $t2, $prefix, $size_p, $list_p, $progress_p,
                          $cgi_p, $force_fmt);
      $noerror = 0;
    };
    print STDERR "$progname: $@" if $@;
    last if ($size_p == 1);
  }
}


sub do_cgi($) {
  my ($muxp) = @_;

  $|=1;

  my $args = "";
  if (!defined ($ENV{REQUEST_METHOD})) {
  } elsif ($ENV{REQUEST_METHOD} eq "GET") {
    $args = $ENV{QUERY_STRING} if (defined($ENV{QUERY_STRING}));
  } elsif ($ENV{REQUEST_METHOD} eq "POST") {
    local $/ = undef;  # read entire file
    $args .= <STDIN>;
  }

  if (!$args &&
      defined($ENV{REQUEST_URI}) && 
      $ENV{REQUEST_URI} =~ m/^(.*?)\?(.*)$/s) {
    $args = $2;
    # for cmd-line debugging
    $ENV{SCRIPT_NAME} = $1 unless defined($ENV{SCRIPT_NAME});
#    $ENV{PATH_INFO} = $1 if (!$ENV{PATH_INFO} && 
#                             $ENV{SCRIPT_NAME} =~ m@^.*/(.*)@s);
  }

  my ($url, $orig_url, $redir, $proxy, $ct);
  foreach (split (/&/, $args)) {
    my ($key, $val) = m/^([^=]+)=(.*)$/;
    $key = url_unquote ($key);
    $val = url_unquote ($val);
    if    ($key eq 'url')   { $url   = $val; }
    elsif ($key eq 'redir') { $redir = $val; }
    elsif ($key eq 'proxy') { $proxy = $val; }
    elsif ($key eq 'ct')    { $ct    = $val; }
    elsif ($key eq 'src')   { $orig_url = $val; } # Unused: only informative.
    else { error ("unknown option: $key"); }
  }

  if ($redir || $proxy) {
    error ("can't specify both url and redir")   if ($redir && $url);
    error ("can't specify both url and proxy")   if ($proxy && $url);
    error ("can't specify both redir and proxy") if ($proxy && $redir);
    my $title = $ENV{PATH_INFO} || '';
    $title =~ s@^/@@s;
    $title = ($redir || $proxy) unless $title;
    $title =~ s@^.*?/@@gs;
    $title =~ s@[?&].*@@gs;
    $title =~ s@\"@%22@gs;

    $ct = 'video/mpeg' unless $ct;
    my $ct2 = $1 if ($ct =~ s/\|(.*)$//s);

    if ($redir) {
      my ($audio) = ($redir =~ s@\|(.*)$@@s);
      error ("can't redir URLs that require muxing") if ($audio);

      # Return a redirect to the underlying video URL.
      binmode (STDOUT, ':raw');
      print STDOUT ("Content-Type: text/html\n" .
                    "Location: $redir\n" .
                    "Content-Disposition: attachment; filename=\"$title\"\n" .
                    "\n" .
                    "<A HREF=\"$redir\">$title</A>\n" .
                    "\n");
    } else {
      # Proxy the data, so that we can feed it a non-browser user agent.

      my $audio = $1 if ($proxy =~ s@\|(.*)$@@s);

      if ($audio) {
        # We need to download both files locally, then mux them, then
        # stream that. Auuugh!

        my $tmp = $ENV{TMPDIR} || "/tmp";
        my $e1 = content_type_ext ($ct);
        my $e2 = content_type_ext ($ct2 || $ct);
        $progname =~ s/\..*?$//s;
        my $video_file = sprintf("$tmp/$progname-V-%08x.$e1",rand(0xFFFFFFFF));
        my $audio_file = sprintf("$tmp/$progname-A-%08x.$e2",rand(0xFFFFFFFF));
        my $muxed_file = sprintf("$tmp/$progname-M-%08x.$e1",rand(0xFFFFFFFF));

        unlink ($video_file, $audio_file, $muxed_file);
        push @rm_r, ($video_file, $audio_file, $muxed_file);

        # So we're downloading two files and muxing them before we have any
        # bytes we can send to the client.  That means that several minutes
        # could go by with 0 data being written, which might make Apache or
        # the browser time out and drop the connection.  So, before we have
        # any real content to write, we write an "X-Heartbeat: ...." header,
        # spitting out a new "." every few seconds.  This means the client
        # header block doesn't actually close until we have the body (which
        # is necessary in order to have the true Content-Length) but we have
        # technically not fallen fully idle.  Let's hope Apache and the
        # client fall for that trick.

        my $progress_p = 'cgi';
        my $hdr = "X-Heartbeat: ";
        print STDOUT $hdr;
        get_url ($proxy, undef, $video_file, undef, 'cgi');
        print STDOUT "\n$hdr";
        get_url ($audio, undef, $audio_file, undef, 'cgi');
        print STDOUT "\n";  # close $hdr

        my %v1 = ( file => $video_file );
        my %v2 = ( file => $audio_file );

        $verbose = -1;
        mux_downloaded_files ($orig_url, $orig_url, $title,
                              \%v1, \%v2, $muxed_file);

        unlink ($video_file, $audio_file);
        open (my $in, '<:raw', $muxed_file) ||
          error ("$orig_url: $muxed_file: $!");

        my @st = stat($in);
        my $size = $st[7];
        unlink ($muxed_file);

        print STDOUT ("Content-Type: $ct\n" .
                      "Content-Length: $size\n" .
                      "Content-Disposition: attachment; filename=\"$title\"\n".
                      "\n");

        binmode (STDOUT, ':raw');
        local $/ = undef;  # read entire file
        while (<$in>) {
          print STDOUT $_;
        }
        close $in;

      } else {
        # Otherwise we can just stream it without involving the disk.
        print STDOUT "Content-Disposition: attachment; filename=\"$title\"\n";
        binmode (STDOUT, ':raw');
        get_url ($proxy, undef, '-');
      }
    }

  } elsif ($url) {
    error ("extraneous crap in URL: $ENV{PATH_INFO}")
      if (defined($ENV{PATH_INFO}) && $ENV{PATH_INFO} ne "");

    my $force_fmt = ($muxp ? 'mux' : undef);
    download_video_url ($url, undef, undef, 0, 0, undef, 1, $force_fmt);

  } else {
    error ("no URL specified for CGI");
  }
}


sub usage() {
  print STDERR "usage: $progname" .
                 " [--verbose] [--quiet] [--progress] [--size]\n" .
           "\t\t   [--title txt] [--prefix txt] [--suffix]\n" .
           "\t\t   [--fmt N] [--no-mux]\n" .
           "\t\t   youtube-or-vimeo-urls ...\n";
  exit 1;
}

sub main() {

  binmode (STDOUT, ':utf8');   # video titles in messages
  binmode (STDERR, ':utf8');

  $progname =~ s/\..*?$//s;    # remove .cgi
  srand(time ^ $$);            # for tmp files

  # historical suckage: the environment variable name is lower case.
  $http_proxy = $ENV{http_proxy} || $ENV{HTTP_PROXY};

  if ($http_proxy && $http_proxy !~ m/^http/si) {
    # historical suckage: allow "host:port" as well as "http://host:port".
    $http_proxy = "http://$http_proxy";
  }

  my @urls = ();
  my $title = undef;
  my $prefix = undef;
  my $size_p = 0;
  my $list_p = 0;
  my $progress_p = 0;
  my $fmt = undef;
  my $expect = undef;
  my $guessp = 0;
  my $muxp = 1;

  while ($#ARGV >= 0) {
    $_ = shift @ARGV;
    if (m/^--?verbose$/)     { $verbose++; }
    elsif (m/^-v+$/)         { $verbose += length($_)-1; }
    elsif (m/^--?q(uiet)?$/) { $verbose--; }
    elsif (m/^--?progress$/) { $progress_p++; }
    elsif (m/^--?suffix$/)   { $append_suffix_p = 1; }
    elsif (m/^--?prefix$/)   { $expect = $_; $prefix = shift @ARGV; }
    elsif (m/^--?title$/)    { $expect = $_; $title = shift @ARGV; }
    elsif (m/^--?size$/)     { $expect = $_; $size_p++; }
    elsif (m/^--?list$/)     { $expect = $_; $list_p++; }
    elsif (m/^--?fmt$/)      { $expect = $_; $fmt = shift @ARGV; }
    elsif (m/^--?mux$/)      { $expect = $_; $muxp = 1; }
    elsif (m/^--?no-?mux$/)  { $expect = $_; $muxp = 0; }
    elsif (m/^--?guess$/)    { $guessp++; }
    elsif (m/^-./)           { usage; }
    else { 
      s@^//@http://@s;
      error ("not a Youtube, Vimeo or Tumblr URL: $_")
        unless (m@^(https?://)?
                   ([a-z]+\.)?
                   ( youtube(-nocookie)?\.com/ |
                     youtu\.be/ |
                     vimeo\.com/ |
                     google\.com/ .* service=youtube |
                     youtube\.googleapis\.com
                     tumblr\.com/ |
                   )@six);
      $fmt = 'mux' if ($muxp && !defined($fmt));
      usage if (defined($fmt) && $fmt !~ m/^\d+|all|mux$/s);
      my @P = ($title, $fmt, $_);
      push @urls, \@P;
      $title = undef;
      $expect = undef;
    }
  }

  error ("$expect applies to the following URLs, so it must come first")
    if ($expect);

  if ($guessp) {
    guess_cipher (undef, $guessp - 1);
    exit (0);
  }

  return do_cgi($muxp) if (defined ($ENV{REQUEST_URI}));

  usage unless ($#urls >= 0);
  foreach (@urls) {
    my ($title, $fmt, $url) = @$_;
    download_video_url ($url, $title, $prefix, 
                        $size_p, $list_p, $progress_p, 0, $fmt);
  }
}

main();
exit 0;
