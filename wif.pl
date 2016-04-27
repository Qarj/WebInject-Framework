#!/usr/bin/perl

# $Id$
# $Revision$
# $Date$

use strict;
use warnings;
use vars qw/ $VERSION /;

$VERSION = '0.03';

#    WebInjectFramework is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    WebInjectFramework is distributed in the hope that it will be useful,
#    but without any warranty; without even the implied warranty of
#    merchantability or fitness for a particular purpose.  See the
#    GNU General Public License for more details.

#    Example: 
#              wif.pl ../WebInject/examples/demo.xml --target skynet --batch demonstration
#              wif.pl ../WebInject/examples/command.xml --target skynet --batch allgood
#              wif.pl ../WebInject/examples/sanitycheck.xml --target skynet --batch veryverybad
#              wif.pl ../WebInject/examples/errormessage.xml --target skynet --batch notgood
#              wif.pl ../WebInject/examples/corrupt.xml --target skynet --batch worstpossible
#              wif.pl ../WebInject/examples/sleep.xml --target skynet --batch tired
#              wif.pl ../WebInject/examples/selenium.xml --target skynet --batch gui

use Getopt::Long;
use File::Basename;
use File::Spec;
use File::Slurp;
use File::Copy qw(copy), qw(move);
use File::Path qw(make_path remove_tree);;
use Cwd;
use Time::HiRes 'time','sleep';
use Config::Tiny;
use XML::Simple;
use XML::Twig;
require Data::Dumper;

local $| = 1; # don't buffer output to STDOUT

# start globally read/write variables declaration - only variables declared here will be read/written directly from subs
my $har_file_content;
my ( $opt_version, $opt_target, $opt_batch, $opt_environment, $opt_use_browsermob_proxy, $opt_no_retry, $opt_help, $opt_keep, $opt_capture_stdout);
my ( $testfile_full, $testfile_name, $testfile_path, $testfile_parent_folder_name );
my ( $config_is_automation_controller );
my ( $web_server_location_full, $web_server_address, $selenium_location_full, $webinject_location, $browsermob_proxy_location_full );
my ( $temp_folder_name );
my $config = Config::Tiny->new;
my $target_config = Config::Tiny->new;
my $global_config = Config::Tiny->new;
my $environment_config = Config::Tiny->new;
my $WEBINJECT_CONFIG;
my ( $std_fh );
# end globally read/write variables

# start globally read variables  - will only be written to from the main script
my ( $yyyy, $mm, $dd, $hour, $minute, $second, $seconds ) = get_date(0); ## no critic(NamingConventions::ProhibitAmbiguousNames)
my $today_home;
my $results_content;
# end globally read variables

get_options_and_config();  # get command line options
$today_home = "$web_server_location_full/$opt_environment/$yyyy/$mm/$dd";

# generate a random folder for the temporary files
$temp_folder_name = create_temp_folder();

# find out what run number we are up to today for this testcase file
my ($run_number, $this_run_home) = create_run_number();

capture_stdout($this_run_home);

# check the testfile to ensure the XML parses - will die if it doesn't
check_testfile_xml_parses_ok();

# generate the config file, and find out where it is
my ($config_file_full, $config_file_name, $config_file_path) = create_webinject_config_file($run_number);

# indicate that WebInject is running the testfile
write_pending_result($run_number);

# there is now a new item in the batch, so the overall summary of everything has to be rebuilt
build_summary_of_batches();

my $testfile_contains_selenium = does_testfile_contain_selenium($testfile_full);
#print "testfile_contains_selenium:$testfile_contains_selenium\n";

my ($proxy_server_pid, $proxy_server_port, $proxy_port) = start_browsermob_proxy($testfile_contains_selenium);

my $selenium_port = start_selenium_server($testfile_contains_selenium);
#print "selenium_port:$selenium_port\n";

display_title_info($testfile_name, $run_number, $config_file_name, $selenium_port, $proxy_port);

call_webinject_with_testfile($config_file_full, $testfile_contains_selenium, $selenium_port, $proxy_port, $this_run_home);

shutdown_selenium_server($selenium_port);

#write_har_file($proxy_port);

shutdown_browsermob_proxy($proxy_server_pid, $proxy_server_port, $proxy_port);

#report_har_file_urls($proxy_port);

publish_results_on_web_server($run_number);

write_final_result($run_number);

# the pending item in the batch is now final, so the overall summary of everything has to be rebuilt
build_summary_of_batches();

# ensure the stylesheets, assets and manual files are on the web server
publish_static_files($run_number);

# tear down
remove_temp_folder($temp_folder_name, $opt_keep);

restore_stdout();

#------------------------------------------------------------------
sub call_webinject_with_testfile {
    my ($_config_file_full, $_testfile_contains_selenium, $_selenium_port, $_proxy_port, $_this_run_home) = @_;

    my $_temp_folder_name = 'temp/' . $temp_folder_name;

    #print {*STDOUT} "config_file_full: [$_config_file_full]\n";

    my $_abs_testfile_full = File::Spec->rel2abs( $testfile_full );
    my $_abs_config_file_full = File::Spec->rel2abs( $_config_file_full );
    my $_abs_temp_folder = File::Spec->rel2abs( $_temp_folder_name ) . q{/};

    #print {*STDOUT} "\n_abs_testfile_full: [$_abs_testfile_full]\n";
    #print {*STDOUT} "_abs_config_file_full: [$_abs_config_file_full]\n";
    #print {*SDDOUT} "_abs_temp_folder: [$_abs_temp_folder]\n";

    my @_args;

    push @_args, $_abs_testfile_full;

    push @_args, '--publish-to';
    push @_args, $_this_run_home;

    if ($_abs_config_file_full) {
        push @_args, '--config';
        push @_args, $_abs_config_file_full;
    }

    if ($_abs_temp_folder) {
        push @_args, '--output';
        push @_args, $_abs_temp_folder;
    }

    if ($config_is_automation_controller eq 'true') {
        push @_args, '--autocontroller';
    }

    if ($opt_no_retry) {
        push @_args, '--ignoreretry';
    }

    # Selenium only options
    if ($_testfile_contains_selenium) {

        if ($_proxy_port) {
            push @_args, '--proxy';
            push @_args, 'localhost:' . $_proxy_port;
        }

        push @_args, '--port';
        push @_args, $_selenium_port;

        # for now we hardcode the browser to Chrome
        push @_args, '--driver';
        push @_args, 'chrome';

    }

    # WebInject test cases expect the current working directory to be where webinject.pl is
    my $_orig_cwd = cwd;
    chdir $webinject_location;

    if (defined $opt_capture_stdout) {
        my $_wi_stdout_file_full = $_this_run_home."webinject_stdout.txt";
        print {*STDOUT} "\nLaunching webinject.pl, STDOUT redirected to $_wi_stdout_file_full\n";
        print {*STDOUT} "    webinject.pl @_args\n";
        system "webinject.pl @_args > $_wi_stdout_file_full 2>&1";
        print {*STDOUT} "\nwebinject.pl execution all done.\n";
    } else {
        # we run it like this so you can see test case execution progress "as it happens"
        system 'webinject.pl', @_args;
    }

    chdir $_orig_cwd;

    return;
}

#------------------------------------------------------------------
sub capture_stdout {
    my ($_output_location) = @_;


    *OLD_STDOUT = *STDOUT;
    *OLD_STDERR = *STDERR;

    if (defined $opt_capture_stdout) {
        open $std_fh, '>>', $_output_location.'wif_stdout.txt';
        *STDOUT = $std_fh;
        *STDERR = $std_fh;

        print {*STDOUT} "\nWebInject Framework Config:\n";
        print {*STDOUT} Data::Dumper::Dumper ( $config );
    }

    return;
}

#------------------------------------------------------------------
sub restore_stdout {

    if (defined $opt_capture_stdout) {
        *STDOUT = *OLD_STDOUT;
        *STDERR = *OLD_STDERR;
    }

    return;
}

#------------------------------------------------------------------
sub get_date {
    my ($_time_offset) = @_;

    ## put the specified date and time into variables - startdatetime - for recording the start time in a format an xsl stylesheet can process
    my @_MONTHS = qw(01 02 03 04 05 06 07 08 09 10 11 12);
    #my @_WEEKDAYS = qw(Sun Mon Tue Wed Thu Fri Sat Sun);
    my ($_SECOND, $_MINUTE, $_HOUR, $_DAYOFMONTH, $_MONTH, $_YEAROFFSET, $_DAYOFWEEK, $_DAYOFYEAR, $_DAYLIGHTSAVINGS) = localtime (time + $_time_offset);
    my $_YEAR = 1900 + $_YEAROFFSET;
    #my $_YY = substr $_YEAR, 2; #year as 2 digits
    $_DAYOFMONTH = sprintf '%02d', $_DAYOFMONTH;
    #my $_WEEKOFMONTH = int(($_DAYOFMONTH-1)/7)+1;
    $_MINUTE = sprintf '%02d', $_MINUTE; #put in up to 2 leading zeros
    $_SECOND = sprintf '%02d', $_SECOND;
    $_HOUR = sprintf '%02d', $_HOUR;
    my $_TIMESECONDS = ($_HOUR * 60 * 60) + ($_MINUTE * 60) + $_SECOND;

    return $_YEAR, $_MONTHS[$_MONTH], $_DAYOFMONTH, $_HOUR, $_MINUTE, $_SECOND, $_TIMESECONDS;
}

#------------------------------------------------------------------
sub display_title_info {
    my ($_testfile_name, $_run_number, $_config_file_name, $_selenium_port, $_proxy_port) = @_;

    my $_selenium_port_info = q{};
    if (defined $_selenium_port) {
        $_selenium_port_info = " [Selenium Port:$_selenium_port]";
    }

    my $_proxy_port_info = q{};
    if (defined $_proxy_port) {
        $_proxy_port_info = " [Proxy Port:$_proxy_port]";
    }

    my $_result = `title temp\\$temp_folder_name $_config_file_name $_run_number:$_testfile_name$_selenium_port_info$_proxy_port_info`;

    return;
}

#------------------------------------------------------------------
sub report_har_file_urls {
    my ($_proxy_port) = @_;

    if (not defined $_proxy_port) {
        return;
    }

    my $_filename = 'temp/' . $temp_folder_name . '/URLs.txt';
    open my $_fh, '>', $_filename or die "Could not open file '$_filename' $!\n";
    binmode $_fh, ':encoding(UTF-8)'; # set binary mode and utf8 character set

    my $doublequote = "\x22"; ## no critic(ValuesAndExpressions::ProhibitEscapedCharacters)
    while ( $har_file_content =~ m/"url":$doublequote([^$doublequote]*)$doublequote/g ) {
        print {$_fh} "$1\n";
    }

    close $_fh or die "Could not close file $_filename\n";

    return;
}

#------------------------------------------------------------------
sub write_har_file {
    my ($_proxy_port) = @_;

    if (not defined $_proxy_port) {
        return;
    }

    # get the har file from browsermob-proxy
    require LWP::Simple;
    my $_url = "http://localhost:9091/proxy/$_proxy_port/har";
    $har_file_content = LWP::Simple::get $_url;

    require Encode;
    $har_file_content = Encode::encode_utf8( $har_file_content );

    # write har file uncompressed
    my $_filename = 'temp/' . $temp_folder_name . '/har.txt';
    open my $_fh, '>', $_filename or die "Could not open file '$_filename' $!\n";
    binmode $_fh; # set binary mode
    print {$_fh} $har_file_content;
    close $_fh or die "Could not close file $_filename\n";

    # write har file compressed
    require Compress::Zlib;
    $_filename = 'temp/' . $temp_folder_name . '/har.gzip';
    open my $_fh2, '>', $_filename or die "Could not open file '$_filename' $!\n";
    binmode $_fh2; # set binary mode
    my $_compressed = Compress::Zlib::memGzip($har_file_content);
    print {$_fh2} $_compressed;
    close $_fh2 or die "Could not close file $_filename\n";

    return;
}

#------------------------------------------------------------------
sub shutdown_browsermob_proxy {
    my ($_proxy_server_pid, $_proxy_server_port, $_proxy_port) = @_;

    if (not defined $_proxy_server_pid) {
        return;
    }

    require LWP::UserAgent;

    # prove that that the proxy port is in use
    #my $_available_port= _find_available_port($_proxy_port);
    #print "_available_port:$_available_port\n";

    # first shutdown the proxy (a bit pointless since we will kill the parent process next)
    if (defined $_proxy_port) {
        LWP::UserAgent->new->delete("http://localhost:$_proxy_server_port/proxy/$_proxy_port");
    }

    # prove that that the proxy server has been shut down
    #$_available_port= _find_available_port($_proxy_port);
    #print "_proxy_port:$_proxy_port\n";
    #print "_available_port:$_available_port\n";

    # now shutdown the proxy server
    my $_result = `taskkill /PID $_proxy_server_pid /T /F`;
    if (not $_result =~ m/SUCCESS.*child process/ ) {
        print {*STDOUT} "ERROR: Did not kill browsermob proxy (pid $_proxy_server_pid) and child processes\n";
    }

    return;
}

#------------------------------------------------------------------
sub shutdown_selenium_server {
    my ($_selenium_port) = @_;

    if (not defined $_selenium_port) {
        return;
    }

    require LWP::Simple;

    my $_url = "http://localhost:$_selenium_port/selenium-server/driver/?cmd=shutDownSeleniumServer";
    my $_content = LWP::Simple::get $_url;
    #print {*STDOUT} "Shutdown Server:$_content\n";

    return;
}

#------------------------------------------------------------------
sub start_selenium_server {
    my ($_testfile_contains_selenium) = @_;

    if (not defined $_testfile_contains_selenium) {
        return;
    }

    # copy chromedriver - source location hardcoded for now
    copy 'C:/selenium-server/chromedriver.exe', "temp/$temp_folder_name/chromedriver.eXe";

    # find free port
    my $_selenium_port = _find_available_port(9001);
    #print "_selenium_port:$_selenium_port\n";

    my $_abs_chromedriver_full = File::Spec->rel2abs( "temp\\$temp_folder_name\\chromedriver.eXe" );
    my $_abs_selenium_log_full = File::Spec->rel2abs( "temp\\$temp_folder_name\\selenium_log.txt" );

    my $_pid = _start_windows_process(qq{cmd /c java -Dwebdriver.chrome.driver="$_abs_chromedriver_full" -Dwebdriver.chrome.logfile="$_abs_selenium_log_full" -jar C:\\selenium-server\\selenium-server-standalone-2.46.0.jar -port $_selenium_port -trustAllSSLCertificates});

    return $_selenium_port;
}

#------------------------------------------------------------------
sub _start_windows_process {
    my ($_command) = @_;

    my $_wmic = "wmic process call create '$_command'"; #
    my $_result = `$_wmic`;
    #print "_wmic:$_wmic\n";
    #print "$_result\n";

    my $_pid;
    if ( $_result =~ m/ProcessId = (\d+)/ ) {
        $_pid = $1;
    }

    return $_pid;
}

#------------------------------------------------------------------
sub __port_available {
    my ($_port) = @_;

    require Socket;

    my $_family = Socket::PF_INET();
    my $_type   = Socket::SOCK_STREAM();
    my $_proto  = getprotobyname 'tcp' or die "getprotobyname: $!\n";
    my $_host   = Socket::INADDR_ANY();  # Use inet_aton for a specific interface

    socket my $_sock, $_family, $_type, $_proto  or die "socket: $!\n";
    my $_name = Socket::sockaddr_in($_port, $_host)     or die "sockaddr_in: $!\n";

    if (bind $_sock, $_name) {
        return 'available';
    }

    return 'in use';
}

sub _find_available_port {
    my ($_start_port) = @_;

    my $_max_attempts = 20;
    foreach my $i (0..$_max_attempts) {
        if (__port_available($_start_port + $i) eq 'available') {
            return $_start_port + $i;
        }
    }

    return 'none';
}

#------------------------------------------------------------------
sub start_browsermob_proxy {
    my ($_testfile_contains_selenium) = @_;

    require LWP::UserAgent;

    if (not defined $opt_use_browsermob_proxy) {
        return;
    }

    if (not $opt_use_browsermob_proxy eq 'true') {
        return;
    }

    # for the moment, a proxy can only be used in conjunction with selenium
    if (not defined $_testfile_contains_selenium) {
        return;
    }

    #my $_cmd = 'subs\start_browsermob_proxy.pl ' . $temp_folder_name;
    #my $_proxy_port = `$_cmd`;

    # we need two ports, one for the proxy (server) server, and the other for the proxy (server)
    # find free port
    # start proxy server
    my $_proxy_server_port = _find_available_port(int(rand 999)+9000);
    my $_proxy_server_pid = _start_windows_process( "cmd /c $browsermob_proxy_location_full -port $_proxy_server_port" );
    #print "_proxy_server_port:$_proxy_server_port\n";

    # start proxy
    my $_proxy_port = _find_available_port(int(rand 999)+10_000);
    _http_post ("http://localhost:$_proxy_server_port/proxy", 'port', $_proxy_port);

    #print "_proxy_port:$_proxy_port\n";

    my $_browsermob_config = Config::Tiny->read( 'plugins/browsermob_proxy/browsermob_proxy.config' );
    foreach my $_blacklist (sort keys %{$_browsermob_config->{'blacklist'}}) {
        #print "_blacklist:$_blacklist\n";
        _http_put ("http://localhost:$_proxy_server_port/proxy/$_proxy_port/blacklist", "regex=http.*$_blacklist.*&status=200");
    }

    foreach my $_rewrite (sort keys %{$_browsermob_config->{'rewrite'}}) {
        print "_rewrite:$_rewrite\n";
        _http_put ("http://localhost:$_proxy_server_port/proxy/$_proxy_port/rewrite", "matchRegex=http.*$_rewrite.*&replace=http://localhost/$_rewrite");
    }

    return $_proxy_server_pid, $_proxy_server_port, $_proxy_port;
}

#------------------------------------------------------------------
sub _http_put {
    my ($_url, $_body) = @_;

    require HTTP::Request;

    my $_agent = LWP::UserAgent->new;
    my $_request = HTTP::Request->new('PUT', $_url);
    $_request->content_type('application/x-www-form-urlencoded');
    $_request->content($_body);
    my $_response;

    #print '_request:' . Data::Dumper::Dumper($_request). "\n\n";

    my $_max = 50;
    my $_try = 0;
    ATTEMPT:
    {
        $_response = Data::Dumper::Dumper ( $_agent->request($_request) );

        if ( ( $_response =~ m/Can[\\]\'t connect to/ ) and $_try++ < $_max ) {
            #print {*STDOUT} "WARN: cannot connect to $_url\n";
            sleep 0.1;
            redo ATTEMPT;
        }
    }

    if ( not $_response =~ m/'_rc' => '200'/ ) {
        print {*STDOUT} "\nERROR: Did not get http response 200 for PUT request\n";
        print {*STDOUT} "    url:$_url\n";
        print {*STDOUT} "   body:$_body\n\n";
    }

    #print "_response:$_response\n";

    return;
}

#------------------------------------------------------------------
sub _http_post {
    my ($_url, @_body) = @_;

    my $_response;

    my $_max = 50;
    my $_try = 0;
    ATTEMPT:
    {
        $_response = Data::Dumper::Dumper ( LWP::UserAgent->new->post($_url, \@_body) );

        if ( ( $_response =~ m/Can[\\]\'t connect to/ ) and $_try++ < $_max ) {
            #print {*STDOUT} "WARN: cannot connect to $_url\n";
            sleep 0.1;
            redo ATTEMPT;
        }
    }
    #print "_response:$_response\n";

    return;
}

#------------------------------------------------------------------
sub does_testfile_contain_selenium {
    my ($_testfile_full) = @_;

    my $_text = read_file($_testfile_full);

    if ($_text =~ m/\$driver->/) {
        return 'true';
    }

    return;
}

#------------------------------------------------------------------
sub publish_static_files {
    my ($_run_number) = @_;

    # favourite icon
    _copy ( 'content/root/*', $web_server_location_full);

    # xsl and css stylesheets plus images
    _make_dir ( $web_server_location_full.'/content/' ) ;
    _copy ( 'content/*.css', $web_server_location_full.'/content/' );
    _copy ( 'content/*.xsl', $web_server_location_full.'/content/' );
    _copy ( 'content/*.jpg', $web_server_location_full.'/content/' );

    # javascripts
    _make_dir ( $web_server_location_full.'/scripts/' ) ;
    _copy ( 'scripts/*.js', $web_server_location_full.'/scripts/' );

    return;
}

#------------------------------------------------------------------
sub publish_results_on_web_server {
    my ($_run_number) = @_;

    $results_content = read_file("temp/$temp_folder_name/results.xml");

    my $_this_run_home = "$today_home/$testfile_parent_folder_name/$testfile_name/results_$_run_number/";

    # put a reference to the stylesheet in the results file
    my $_results = '<?xml version="1.0" encoding="ISO-8859-1"?>'."\n";
    $_results .= '<?xml-stylesheet type="text/xsl" href="/content/Results.xsl"?>'."\n";
    $_results .= $results_content;

    # insert info from wif into the results
    my $_wif_content = _build_results_wif_content($_run_number);
    $_results =~ s{</test-summary>}{</test-summary>$_wif_content}s;

    _write_file("$today_home/$testfile_parent_folder_name/$testfile_name/results_$_run_number/results_$_run_number.xml", $_results);

    # copy captured email files to web server 
    _copy ( "temp/$temp_folder_name/*.eml", $_this_run_home);

    # copy any .txt files over
    _copy ( "temp/$temp_folder_name/*.txt", $_this_run_home);

    # copy any .7z files over - e.g. har.7z
    _copy ( "temp/$temp_folder_name/*.7z", $_this_run_home);

    # copy .htm and .html files over
    _copy ( "temp/$temp_folder_name/*.htm*", $_this_run_home);

    # copy .css and .less files over
    _copy ( "temp/$temp_folder_name/*ss", $_this_run_home);

    # copy .jpg and .png files over
    _copy ( "temp/$temp_folder_name/*.jpg", $_this_run_home);
    _copy ( "temp/$temp_folder_name/*.png", $_this_run_home);

    # copy the .js files over
    _copy ( "temp/$temp_folder_name/*.js", $_this_run_home);

    # copy chromedriver.log file over as chromedriver.txt so we do not need another MIME type
    _copy ( "temp/$temp_folder_name/chromedriver.log", "$_this_run_home".'chromedriver.txt');

    # copy http.log file over as http.txt so we do not need another MIME type
    _copy ( "temp/$temp_folder_name/http.log", "$_this_run_home".'http.txt');

    # split the http.log into a file for each step
    # perhaps WebInject can do this, and write the log at the same time

    return;
}

#------------------------------------------------------------------
sub _build_results_wif_content {
    my ($_run_number) = @_;

    my $_content = "\n\n";
    $_content .= "    <wif>\n";
    $_content .= "        <environment>$opt_environment</environment>\n";
    $_content .= "        <yyyy>$yyyy</yyyy>\n";
    $_content .= "        <mm>$mm</mm>\n";
    $_content .= "        <dd>$dd</dd>\n";
    $_content .= "        <batch>$opt_batch</batch>\n";
    $_content .= "    </wif>\n";

    return $_content;
}

#------------------------------------------------------------------
sub _copy {
    my ($_source, $_dest) = @_;

    my @_source_files = glob $_source;

    foreach my $_source_file (@_source_files) {
        copy $_source_file, $_dest;
    }

    return;
}

#------------------------------------------------------------------
sub write_final_result {
    my ($_run_number) = @_;

    _write_final_record( "$today_home/All_Batches/$opt_batch/$testfile_parent_folder_name".'_'."$testfile_name".'_'."$_run_number".'.txt', $_run_number );

    _build_batch_summary();

    return;
}

#------------------------------------------------------------------
sub _write_final_record {
    my ($_file_full, $_run_number) = @_;

    if ( $results_content =~ m{</test-summary>}i ) {
        # WebInject ran to completion - all ok
    } else {
        # WebInject did not start, or crashed part way through
        _write_corrupt_record($_file_full, $_run_number, 'WebInject abnormal end - run manually to diagnose');
        return;
    }

    # here we parse the xml file in an eval, and capture any error returned (in $@)
    my $_message;
    my $_result = eval { XMLin($results_content) };

    if ($@) {
        $_message = $@;
        $_message =~ s{ at C:.*}{}g; # remove misleading reference Parser.pm
        $_message =~ s{\n}{}g; # remove line feeds
        #$_message =~ s/[&<>]//g;
        $_message =~ s/[&]/{AMPERSAND}/g;
        $_message =~ s/[<]/{LT}/g;
        $_message =~ s/[>]/{GT}/g;
        _write_corrupt_record($_file_full, $_run_number, "$_message in results.xml");
        print {*STDOUT} "WebInject results.xml could not be parsed - CORRUPT\n";
        return;
    }

    my $_twig = XML::Twig->new();

    $_twig->parsefile("temp/$temp_folder_name/results.xml");
    my $_root = $_twig->root;

    my $_start_time = $_root->first_child('test-summary')->first_child_text('start-time');
    my $_start_seconds = $_root->first_child('test-summary')->first_child_text('start-seconds');
    my $_start_date_time = $_root->first_child('test-summary')->first_child_text('start-date-time');
    my $_total_run_time = $_root->first_child('test-summary')->first_child_text('total-run-time');
    my $_max_response_time = $_root->first_child('test-summary')->first_child_text('max-response-time'); $_max_response_time = sprintf '%.1f', $_max_response_time;
    my $_test_cases_run = $_root->first_child('test-summary')->first_child_text('test-cases-run');
    #my $_test_cases_passed = $_root->first_child('test-summary')->first_child_text('test-cases-passed');
    my $_test_cases_failed = $_root->first_child('test-summary')->first_child_text('test-cases-failed');
    my $_assertion_skips = $_root->first_child('test-summary')->first_child_text('assertion-skips');
    #my $_verifications_passed = $_root->first_child('test-summary')->first_child_text('verifications-passed');
    #my $_verifications_failed = $_root->first_child('test-summary')->first_child_text('verifications-failed');
    my $_sanity_check_passed = $_root->first_child('test-summary')->first_child_text('sanity-check-passed');

    my ( $_yyyy, $_mm, $_dd, $_hour, $_minute, $_second, $_seconds ) = get_date(0);
    my $_end_date_time = "$_yyyy-$_mm-$_dd".'T'."$_hour:$_minute:$_second";

    my $_record;

    $_record .= qq|   <run id="$opt_batch">\n|;
    $_record .= qq|      <batch_name>$opt_batch</batch_name>\n|;
    $_record .= qq|      <environment>$opt_environment</environment>\n|;
    $_record .= qq|      <test_parent_folder>$testfile_parent_folder_name</test_parent_folder>\n|;
    $_record .= qq|      <test_name>$testfile_name</test_name>\n|;
    $_record .= qq|      <total_run_time>$_total_run_time</total_run_time>\n|;
    $_record .= qq|      <test_steps_failed>$_test_cases_failed</test_steps_failed>\n|;
    $_record .= qq|      <test_steps_run>$_test_cases_run</test_steps_run>\n|;
    $_record .= qq|      <assertion_skips>$_assertion_skips</assertion_skips>\n|;
    $_record .= qq|      <sanity_check_passed>$_sanity_check_passed</sanity_check_passed>\n|;
    $_record .= qq|      <max_response_time>$_max_response_time</max_response_time>\n|;
    $_record .= qq|      <target>$opt_target</target>\n|;
    $_record .= qq|      <yyyy>$yyyy</yyyy>\n|;
    $_record .= qq|      <mm>$mm</mm>\n|;
    $_record .= qq|      <dd>$dd</dd>\n|;
    $_record .= qq|      <run_number>$_run_number</run_number>\n|;
    $_record .= qq|      <start_time>$_start_time</start_time>\n|;
    $_record .= qq|      <start_date_time>$_start_date_time</start_date_time>\n|;
    $_record .= qq|      <end_time>$_end_date_time</end_time>\n|;
    $_record .= qq|      <start_seconds>$_start_seconds</start_seconds>\n|;
    $_record .= qq|      <end_seconds>$_seconds</end_seconds>\n|;
    $_record .= qq|      <status>NORMAL</status>\n|;
    $_record .= qq|   </run>\n|;

    _write_file ($_file_full, $_record);

    return;
}

#------------------------------------------------------------------
sub _write_corrupt_record {
    my ($_file_full, $_run_number, $_message) = @_;

    my $_record;

    my $_start_date_time = "$yyyy-$mm-$dd".'T'."$hour:$minute:$second";

    my ( $_yyyy, $_mm, $_dd, $_hour, $_minute, $_second, $_seconds ) = get_date(0);
    my $_end_date_time = "$_yyyy-$_mm-$_dd".'T'."$_hour:$_minute:$_second";

    $_record .= qq|   <run id="$opt_batch">\n|;
    $_record .= qq|      <batch_name>$opt_batch</batch_name>\n|;
    $_record .= qq|      <environment>$opt_environment</environment>\n|;
    $_record .= qq|      <test_parent_folder>$testfile_parent_folder_name</test_parent_folder>\n|;
    $_record .= qq|      <test_name>$testfile_name</test_name>\n|;
    $_record .= qq|      <total_run_time>0</total_run_time>\n|;
    $_record .= qq|      <test_steps_failed>0</test_steps_failed>\n|;
    $_record .= qq|      <test_steps_run>0</test_steps_run>\n|;
    $_record .= qq|      <assertion_skips></assertion_skips>\n|;
    $_record .= qq|      <sanity_check_passed>true</sanity_check_passed>\n|;
    $_record .= qq|      <max_response_time>0.0</max_response_time>\n|;
    $_record .= qq|      <target>$opt_target</target>\n|;
    $_record .= qq|      <yyyy>$yyyy</yyyy>\n|;
    $_record .= qq|      <mm>$mm</mm>\n|;
    $_record .= qq|      <dd>$dd</dd>\n|;
    $_record .= qq|      <run_number>$_run_number</run_number>\n|;
    $_record .= qq|      <start_time>unused</start_time>\n|;
    $_record .= qq|      <start_date_time>$_start_date_time</start_date_time>\n|;
    $_record .= qq|      <end_time>$_end_date_time</end_time>\n|;
    $_record .= qq|      <start_seconds>$seconds</start_seconds>\n|;
    $_record .= qq|      <end_seconds>$_seconds</end_seconds>\n|;
    $_record .= qq|      <status>CORRUPT</status>\n|;
    $_record .= qq|      <status_message>[$testfile_parent_folder_name/$testfile_name results.xml] $_message</status_message>\n|;
    $_record .= qq|   </run>\n|;

    _write_file ($_file_full, $_record);

    return;
}

#------------------------------------------------------------------
sub build_summary_of_batches {

    my $_batch_summary_record_full = "$today_home/All_Batches/$opt_batch".'_summary.record';

    _lock_file( $_batch_summary_record_full );

    _write_summary_record( $_batch_summary_record_full );

    # create an array containing all files representing summary records for all of todays batches
    my @_summary_records = glob("$today_home/All_Batches/".'*.record');

    # sort by date created, ascending
    my @_sorted_summary = reverse sort { -C $a <=> -C $b } @_summary_records;

    # write the header
    my $_summary = qq|<?xml version="1.0" encoding="ISO-8859-1"?>\n|;
    $_summary .= qq|<?xml-stylesheet type="text/xsl" href="/content/Summary.xsl"?>\n|;
    $_summary .= qq|<summary version="2.0">\n|;
    $_summary .= qq|    <channel>\n|;

    # write all the batch records
    foreach (@_sorted_summary) {
        $_summary .= read_file($_);
    }

    # write the footer
    $_summary .= qq|    </channel>\n|;
    $_summary .= qq|</summary>\n|;

    # dump summary xml file from memory into file system
    my $_overall_summary_full = "$today_home/All_Batches/Summary.xml";

    # save the file to todays area, and a copy to environment root
    _write_file ( $_overall_summary_full, $_summary );
    _write_file ( $web_server_location_full."/$opt_environment/Summary.xml", $_summary );

    # unlock batch xml file
    _unlock_file( $_batch_summary_record_full );

    return;
}

#------------------------------------------------------------------
sub _write_summary_record {
    my ($_file_full) = @_;

    my $_twig = XML::Twig->new();
    $_twig->parsefile( "$today_home/All_Batches/$opt_batch".'.xml' );
    my $_root = $_twig->root;

    my $_start_time = _get_earliest_start_time($_root);
    my $_end_time = _get_largest_end_time($_root);

    my $_number_of_pending_items = _get_number_of_pending_items($_root);

    # calculate the number of items in the batch - pending items are not counted
    my $_number_of_items = $_root->children_count() - $_number_of_pending_items;

    # $_items_text will look like [1 item] or [5 items] or [4 items/1 pending]
    my $_items_text = _build_items_text($_number_of_items, $_number_of_pending_items);

    my $_number_of_sanity_failures = _get_number_of_sanity_failures($_root);

    my $_number_of_failures = _get_number_of_failures($_root);

    my $_total_run_time_seconds = _get_total_run_time_seconds($_root);

    my $_start_time_seconds = _get_start_time_seconds($_root);
    my $_end_time_seconds = _get_end_time_seconds($_root);

    my $_elapsed_seconds = $_end_time_seconds - $_start_time_seconds;
    my $_elapsed_minutes = sprintf '%.1f', ($_elapsed_seconds / 60);

    # now it is possible to calculate a concurrency factor
    # from this we can infer approximately how much time we saved by running the tests in parallel vs one after the other
    my $_concurrency;
    if ($_elapsed_seconds > 0) {
        $_concurrency = sprintf '%.1f', ($_total_run_time_seconds / $_elapsed_seconds);
    } else {
        $_concurrency = 0;
    }

    # build concurrency text
    my $_concurrency_text = "(Concurrency $_concurrency)";
    if ($_concurrency == 0) { $_concurrency_text = q{}; }

    my $_total_steps_run = _get_total_steps_run($_root);

    my ($_status, $_status_message) = _get_status($_root);

    # build overall summary text
    my $_overall = 'PASS';
    if ($_number_of_pending_items > 0) { $_overall = 'PEND'; }
    if ($_number_of_failures > 0) { $_overall = 'FAIL'; }
    if ($_number_of_sanity_failures > 0) { $_overall = 'SANITY CHECK FAILED'; $_concurrency_text = q{}; }
    if ($_status eq 'CORRUPT') { $_overall = 'CORRUPT'; $_concurrency_text = q{}; }

    # get date for yesterday
    my ( $_yesterday_yyyy, $_yesterday_mm, $_yesterday_dd ) = get_date( - 86_400);

    my $_record;

    $_record .= qq|      <title>$opt_environment Summary</title>\n|;
    $_record .= qq|      <link>http://$web_server_address/$opt_environment/$_yesterday_yyyy/$_yesterday_mm/$_yesterday_dd/All_Batches/Summary.xml</link>\n|;
    $_record .= qq|      <description>WebInject Framework Batch Summary</description>\n|;
    $_record .= qq|      <item>\n|;
    $_record .= '         <title>';

    if ($_status eq 'CORRUPT' ) {
        $_record .= qq|$_overall $dd/$mm $_start_time  - $_end_time $_items_text $opt_batch: $_status_message</title>\n|;
    } elsif ($_number_of_sanity_failures > 0) {
        $_record .= qq|$_overall $dd/$mm $_start_time  - $_end_time $_items_text $opt_batch: $_number_of_sanity_failures SANITY FAILURE(s), $_number_of_failures/$_total_steps_run FAILED, $_elapsed_minutes mins $_concurrency_text *$opt_target*</title>\n|;
    } else {
    	if ($_number_of_failures > 0) {
            $_record .= qq|$_overall $dd/$mm $_start_time  - $_end_time $_items_text $opt_batch: $_number_of_failures/$_total_steps_run FAILED, $_elapsed_minutes mins $_concurrency_text *$opt_target*</title>\n|;
    	} else {
            $_record .= qq|$_overall $dd/$mm $_start_time  - $_end_time $_items_text $opt_batch: ALL $_total_steps_run steps OK, $_elapsed_minutes mins $_concurrency_text *$opt_target*</title>\n|;
    	}
    }

    $_record .= qq|      <link>http://$web_server_address/$opt_environment/$yyyy/$mm/$dd/All_Batches/$opt_batch.xml</link>\n|;
    $_record .= qq|         <description></description>\n|;
    $_record .= qq|         <pubDate>$dd/$mm/$yyyy $hour:$minute</pubDate>\n|;
    $_record .= qq|      </item>\n|;

    _write_file ($_file_full, $_record);

    return;
}

#------------------------------------------------------------------
sub _build_items_text {
    my ($_number_of_items, $_number_of_pending_items) = @_;

    # singular or plural
    my $_items_word;
    if ( $_number_of_items == 1) {
        $_items_word = 'item';
    } else {
        $_items_word = 'items';
    }

    # if there are some pending items, we need a different text
    my $_items_text;
    if ($_number_of_pending_items == 0)
    {
        $_items_text = "[$_number_of_items $_items_word]";
    } else {
        $_items_text = "[$_number_of_items $_items_word/$_number_of_pending_items pending]";
    }

    return $_items_text;
}

#------------------------------------------------------------------
sub _get_status {
    my ($_root) = @_;

    # example tags: <status>CORRUPT</status>
    #               <status-message>Not well formed at line 582</status-message>

    # for the moment, status-message is only set when status is corrupt
    my $_status = 'NORMAL';
    my $_status_message;
    my $_elt = $_root;
    while ( $_elt = $_elt->next_elt($_root,'status_message') ) {
        if ( $_elt->field() ) {
            $_status_message = $_elt->field();
            $_status = 'CORRUPT';
        }
    }

    return $_status, $_status_message;
}

#------------------------------------------------------------------
sub _get_total_steps_run {
    my ($_root) = @_;

    # example tag: <testcasesrun>2</testcasesrun>

    my $_total_run = 0;
    my $_elt = $_root;
    while ( $_elt= $_elt->next_elt($_root,'test_steps_run') ) {
        $_total_run += $_elt->field();
    }

    return $_total_run;
}

#------------------------------------------------------------------
sub _get_end_time_seconds {
    my ($_root) = @_;

    # example tag: <endseconds>75089</endseconds>

    my $_end_seconds = 0;
    my $_elt = $_root;
    while ( $_elt= $_elt->next_elt($_root,'end_seconds') ) {
        if ($_elt->field() > $_end_seconds) {
            $_end_seconds = $_elt->field();
        }
    }

    return $_end_seconds;
}

#------------------------------------------------------------------
sub _get_start_time_seconds {
    my ($_root) = @_;

    # example tag: <startseconds>75059</startseconds>

    # there are 86400 seconds in a day, we need to find the smallest start time in seconds
    my $_start_seconds = 86_400;
    my $_elt = $_root;
    while ( $_elt= $_elt->next_elt($_root,'start_seconds') ) {
        if ($_elt->field() < $_start_seconds) {
            $_start_seconds = $_elt->field();
        }
    }

    return $_start_seconds;
}

#------------------------------------------------------------------
sub _get_total_run_time_seconds {
    my ($_root) = @_;

    # example tag: <totalruntime>0.537</totalruntime>

    my $_elt = $_root;
    my $_total_run_time = 0;
    while ( $_elt= $_elt->next_elt($_root,'total_run_time') ) {
      	$_total_run_time += $_elt->field();
    }

    # format to 0 decimal places
    return sprintf '%.0f', $_total_run_time;
}

#------------------------------------------------------------------
sub _get_number_of_failures {
    my ($_root) = @_;

    # assume we do not have any sanity failures
    my $_num_failures = 0;

    my $_elt = $_root;
    while ( $_elt = $_elt->next_elt( $_root,'test_steps_failed') ) {
        $_num_failures += $_elt->field();
    }

    return $_num_failures;
}

#------------------------------------------------------------------
sub _get_number_of_sanity_failures {
    my ($_root) = @_;

    # assume we do not have any sanity failures
    my $_num_failures = 0;

    my $_elt = $_root;
    while ( $_elt = $_elt->next_elt( $_root,'sanity_check_passed') ) {
        if ($_elt->field() eq 'false' ) {
            $_num_failures  += 1;
        }
    }

    return $_num_failures;
}

#------------------------------------------------------------------
sub _get_number_of_pending_items {
    my ($_root) = @_;

    # assume we do not have any pending items
    my $_num_pending = 0;

    my $_elt = $_root;
    while ( $_elt = $_elt->next_elt( $_root,'end_time') ) {
        if ($_elt->field() eq 'PENDING' ) {
            $_num_pending += 1;
        }
    }

    return $_num_pending;
}

#------------------------------------------------------------------
sub _get_earliest_start_time {
    my ($_root) = @_;

    # example tag: <startdatetime>2016-04-05T20:50:59</startdatetime>
    # the very first run in the batch will always contain the earliest start time

    my $_start_time = $_root->first_child('run')->first_child_text('start_date_time');

    # just return the time portion of the date time string
    return substr $_start_time, 11;
}

#------------------------------------------------------------------
sub _get_largest_end_time {
    my ($_root) = @_;

    # example tag: <end_time>2016-04-05T20:51:00</end_time>
    # we do not know which run in the batch ended last, so we have to examine all of them

    my $_elt = $_root;
    my $_end_time = $_root->last_child('run')->last_child_text('end_time');
    while ( $_elt = $_elt->next_elt($_root,'end_time') )
      {
        #cmp comparison operator -1 if string smaller, 0 if the same, 1 if first string greater than second
        if ( ($_elt->field() cmp $_end_time) == 1) {
      	        $_end_time=$_elt->field();
            }
      }

    if (length $_end_time < 11) {
        # there is not an end time, batch is still pending
        return q{};
    }

    # just return the time portion of the date time string
    return substr $_end_time, 11;
}

#------------------------------------------------------------------
sub write_pending_result {
    my ($_run_number) = @_;

    _make_dir( "$today_home/All_Batches" );

    _make_dir( "$today_home/All_Batches/$opt_batch" );

    _write_pending_record( "$today_home/All_Batches/$opt_batch/$testfile_parent_folder_name".'_'."$testfile_name".'_'."$_run_number".'.txt', $_run_number );

    _build_batch_summary();

    return;
}

#------------------------------------------------------------------
sub _build_batch_summary {

    # lock batch xml file so parallel instances of wif.pl cannot update it
    my $_batch_full = "$today_home/All_Batches/$opt_batch".'.xml';
    _lock_file($_batch_full);

    # create an array containing all files representent runs in the batch
    my @_runs = glob("$today_home/All_Batches/$opt_batch/".'*.txt');

    # sort by date created, ascending
    my @_sorted_runs = reverse sort { -C $a <=> -C $b } @_runs;

    # write the header
    my $_batch = qq|<?xml version="1.0" encoding="ISO-8859-1"?>\n|;
    $_batch .= qq|<?xml-stylesheet type="text/xsl" href="/content/Batch.xsl"?>\n|;
    $_batch .= qq|<batch>\n|;

    # write all the run records
    foreach (@_sorted_runs) {
        $_batch .= read_file($_);
    }

    # write the footer
    $_batch .= qq|</batch>\n|;

    # dump batch xml file from memory into file system
    _write_file ("$today_home/All_Batches/$opt_batch".'.xml', $_batch);

    # unlock batch xml file
    _unlock_file($_batch_full);

    return;
}


#------------------------------------------------------------------
sub _write_file {
    my ($_file_full, $_file_content) = @_;

    open my $_FILE, '>', "$_file_full" or die "\nERROR: Failed to create $_file_full\n\n";
    print {$_FILE} $_file_content;
    close $_FILE or die "\nERROR: Failed to close $_file_full\n\n";

    return;
}

#------------------------------------------------------------------
sub _write_pending_record {
    my ($_file_full, $_run_number) = @_;

    my $_record;

    my $_start_date_time = "$yyyy-$mm-$dd".'T'."$hour:$minute:$second";

    $_record .= qq|   <run id="$opt_batch">\n|;
    $_record .= qq|      <batch_name>$opt_batch</batch_name>\n|;
    $_record .= qq|      <environment>$opt_environment</environment>\n|;
    $_record .= qq|      <test_parent_folder>$testfile_parent_folder_name</test_parent_folder>\n|;
    $_record .= qq|      <test_name>$testfile_name</test_name>\n|;
    $_record .= qq|      <total_run_time>0</total_run_time>\n|;
    $_record .= qq|      <test_steps_failed>0</test_steps_failed>\n|;
    $_record .= qq|      <test_steps_run>0</test_steps_run>\n|;
    $_record .= qq|      <assertion_skips></assertion_skips>\n|;
    $_record .= qq|      <sanity_check_passed>true</sanity_check_passed>\n|;
    $_record .= qq|      <max_response_time>0.0</max_response_time>\n|;
    $_record .= qq|      <target>$opt_target</target>\n|;
    $_record .= qq|      <yyyy>$yyyy</yyyy>\n|;
    $_record .= qq|      <mm>$mm</mm>\n|;
    $_record .= qq|      <dd>$dd</dd>\n|;
    $_record .= qq|      <run_number>$_run_number</run_number>\n|;
    $_record .= qq|      <start_time>unused</start_time>\n|;
    $_record .= qq|      <start_date_time>$_start_date_time</start_date_time>\n|;
    $_record .= qq|      <end_time>PENDING</end_time>\n|;
    $_record .= qq|      <start_seconds>$seconds</start_seconds>\n|;
    $_record .= qq|      <end_seconds>$seconds</end_seconds>\n|;
    $_record .= qq|      <status>NORMAL</status>\n|;
    $_record .= qq|   </run>\n|;

    _write_file ($_file_full, $_record);

    return;
}

#------------------------------------------------------------------
sub check_testfile_xml_parses_ok {

    my $_xml = read_file($testfile_full);

    # for convenience, WebInject allows ampersand and less than to appear in xml data, so this needs to be masked
    $_xml =~ s/&/{AMPERSAND}/g;
    $_xml =~ s/\\</{LESSTHAN}/g;

    # here we parse the xml file in an eval, and capture any error returned (in $@)
    my $_message;
    my $_result = eval { XMLin($_xml) };

    if ($@) {
        $_message = $@;
        $_message =~ s{ at C:.*}{}g; # remove misleading reference Parser.pm
        $_message =~ s{\n}{}g; # remove line feeds
        die "\n".$_message." in $testfile_full\n";
    }

    return;
}

#------------------------------------------------------------------
sub create_run_number {

    if (not -e "$web_server_location_full" ) {
        die "Web server location of $web_server_location_full does not exist\n";
    }

    # if they do not exist already, folders are created for this test file for todays date
    _make_dir( "$web_server_location_full/$opt_environment" );
    _make_dir( "$web_server_location_full/$opt_environment/$yyyy" );
    _make_dir( "$web_server_location_full/$opt_environment/$yyyy/$mm" );
    _make_dir( "$today_home" );
    _make_dir( "$today_home/$testfile_parent_folder_name" );
    _make_dir( "$today_home/$testfile_parent_folder_name/$testfile_name" );

    my $_run_number_full = "$today_home/$testfile_parent_folder_name/$testfile_name/Run_Number.txt";
    _lock_file($_run_number_full);
    my $_run_number = _increment_run_number($_run_number_full);
    _unlock_file($_run_number_full);

    # create a folder for this run number
    my $_this_run_home = "$today_home/$testfile_parent_folder_name/$testfile_name/results_$_run_number/";
    _make_dir( $_this_run_home );

    return $_run_number, $_this_run_home;
}

#------------------------------------------------------------------
sub _increment_run_number {
    my ($_run_number_full) = @_;

    my $_run_number;
    if (-e $_run_number_full) {
        my $_run_number_string = read_file($_run_number_full);
        if ( $_run_number_string =~ m/([\d]*)/ ) {
            $_run_number = $1;
        }
    }

    if (! $_run_number) {
        $_run_number = 1000;
    }

    $_run_number++;

    open my $RUNFILE, '>', "$_run_number_full" or die "\nERROR: Failed to create $_run_number_full\n\n";
    print {$RUNFILE} "$_run_number";
    close $RUNFILE or die "\nERROR: Failed to close $_run_number_full\n\n";

    return $_run_number;
}

#------------------------------------------------------------------
sub _unlock_file {
    my ($_file_to_unlock_full) = @_;

    my $_unlocked_file_indicator = $_file_to_unlock_full.'_Unlocked';
    my $_locked_file_indicator = _prepend_to_filename('Locked_', $_file_to_unlock_full);
    #print "    move\n$_locked_file_indicator".'_'."$temp_folder_name\n".$_unlocked_file_indicator."\n\n";
    move $_locked_file_indicator."_$temp_folder_name", $_unlocked_file_indicator; 

    return;
}

#------------------------------------------------------------------
sub _lock_file {
    my ($_file_to_lock_full) = @_;

    # first the file we want to lock may not even exist, in which case we create it
    my $_unlocked_file_indicator = $_file_to_lock_full.'_Unlocked';
    my $_locked_file_indicator = _prepend_to_filename('Locked_', $_file_to_lock_full);
    if (not -e "$_unlocked_file_indicator" ) {
        #print "file is not unlocked: $_unlocked_file_indicator\n";
        # file is not unlocked
        if (not glob("$_locked_file_indicator".'_*') ) {
            #print "file is not locked either: $_locked_file_indicator".'_*'."\n";
            # file is not locked either, so it must not exist
            # so we can create a file indicating that the file is unlocked
            _touch($_unlocked_file_indicator);
        }
    }

    # now to actually lock the file
    # we do this by renaming the Unlocked indicator file to the name Locked_filename.filesufix_tempfoldername
    # the temp folder name is unique to this process
    my $_max = 200;
    my $_try = 0;
    ATTEMPT:
    {
        eval {
            #print "move\n$_unlocked_file_indicator\n"."$_locked_file_indicator".'_'."$temp_folder_name\n\n";
            move $_unlocked_file_indicator, $_locked_file_indicator.'_'.$temp_folder_name or die "Cannot lock file\n";
        }; # eval needs a semicolon

        # if we failed to lock the file but there are attempts remaining
        if ( $@ and $_try++ < $_max ) {
            # only write a message to STDOUT every 25 attempts
            #if ( ($_try / 25) == int($_try / 25) ) {
                print {*STDOUT} "WARN: $@    Failed try $_try to lock $_file_to_lock_full\n    Lock file: $_locked_file_indicator".q{_}."$temp_folder_name\n";
            #}
            sleep rand 0.3;
            redo ATTEMPT;
        }
    }

    if ($@) {
        # we can get here if a parallel process aborts at exactly the wrong spot
        # so we forcibly lock the file
        print {*STDOUT} "\nError: $@ Failed to lock $_file_to_lock_full after $_max tries\n\n";
        print {*STDOUT} "Executing fail safe - deleting lock and creating our own lock\n\n";
        unlink glob($_locked_file_indicator.'_*');
        unlink $_unlocked_file_indicator;
        _touch($_locked_file_indicator.'_'.$temp_folder_name);
        # this might screw things up a little, but it prevents things being screwed up a lot (i.e. no more test results for the rest of the day)
        # people just have to rerun their most recent tests and all should be fine
    } else {
        #print "Successfully locked: $_file_to_lock_full\n\n\n";
    }

    # now we have locked the file by fair means or by foul

    return;
}


#------------------------------------------------------------------
sub _touch {
    my ($_file_full) = @_;

    open my $TOUCHFILE, '>', "$_file_full" or die "\nERROR: Failed to create $_file_full\n\n";
    close $TOUCHFILE or die "\nERROR: Failed to close $_file_full\n\n";

    return;
}

#------------------------------------------------------------------
sub _prepend_to_filename {
    my ($_string, $_file_full) = @_;

    my ($_file_name, $_file_path, $_file_suffix) = fileparse($_file_full, ('.xml', '.txt', '.html', '.record'));

    return $_file_path.$_string.$_file_name.$_file_suffix;

}

#------------------------------------------------------------------
sub _make_dir {
    my ($_new_dir) = @_;

    if (not -e "$_new_dir" ) {
        mkdir "$_new_dir" or die "Could not create folder $_new_dir\n";
    }

    return;
}

#------------------------------------------------------------------
sub create_webinject_config_file {
    my ($_run_number) = @_;

    if ( not -e "environment_config/$opt_environment.config" ) {
        die "Could not find environment_config/$opt_environment.config\n";
    }

    if ( not -e "environment_config/$opt_environment" ) {
        die "Could not find folder environment_config/$opt_environment\n";
    }

    # if $opt_target contains an alias, change it to the real value
    my $_alias = Config::Tiny->new;
    if (-e "environment_config/$opt_environment/_alias.config") {
        $_alias = Config::Tiny->read( "environment_config/$opt_environment/_alias.config" );

        if (defined $_alias->{_}->{$opt_target}) {
            $opt_target = $_alias->{_}->{$opt_target};
        }
    }

    if (not -e "environment_config/$opt_environment/$opt_target.config") {
        die "Could not find environment_config/$opt_environment/$opt_target.config\n";
    }

    $target_config = Config::Tiny->read( "environment_config/$opt_environment/$opt_target.config" );

    $environment_config = Config::Tiny->read( "environment_config/$opt_environment.config" );

    if (-e 'environment_config/_global.config') {
        $global_config = Config::Tiny->read( 'environment_config/_global.config' );
    }

    my $_config_file_full = "temp/$temp_folder_name/$opt_target.xml";
    open $WEBINJECT_CONFIG, '>' ,"$_config_file_full" or die "\nERROR: Failed to open $_config_file_full for writing\n\n";
    print {$WEBINJECT_CONFIG} "<root>\n";
    _write_webinject_config('main');
    _write_webinject_config('userdefined');
    _write_webinject_config('autoassertions');
    _write_webinject_config('smartassertions');
    _write_webinject_wif_config($_run_number);
    print {$WEBINJECT_CONFIG} "</root>\n";
    close $WEBINJECT_CONFIG or die "\nCould not close $_config_file_full\n\n";

    my ($_config_file_name, $_config_file_path) = fileparse($_config_file_full,'.xml');

    return $_config_file_full, $_config_file_name, $_config_file_path;
}

#------------------------------------------------------------------
sub _write_webinject_config {
    my ($_section) = @_;

    # config parameters defined under [main] will be written at the root level of the WebInject config
    my $_indent = q{};
    if (not $_section eq 'main') {
        $_indent = q{    };
        print {$WEBINJECT_CONFIG} "    <$_section>\n";
    }

    foreach my $_parameter (sort keys %{$target_config->{$_section}}) {
        print {$WEBINJECT_CONFIG} "    $_indent<$_parameter>";
        print {$WEBINJECT_CONFIG} "$target_config->{$_section}->{$_parameter}";
        print {$WEBINJECT_CONFIG} "</$_parameter>\n";
    }

    foreach my $_parameter (sort keys %{$environment_config->{$_section}}) {
        if ( $target_config->{$_section}->{$_parameter} ) {
            # _target_config takes priority - parameter has already been written
            next;
        }

        print {$WEBINJECT_CONFIG} "    $_indent<$_parameter>";
        print {$WEBINJECT_CONFIG} "$environment_config->{$_section}->{$_parameter}";
        print {$WEBINJECT_CONFIG} "</$_parameter>\n";
    }

    foreach my $_parameter (sort keys %{$global_config->{$_section}}) {
        if ( $target_config->{$_section}->{$_parameter} ) {
            # _target_config takes priority - parameter has already been written
            next;
        }

        if ( $environment_config->{$_section}->{$_parameter} ) {
            # _environment_config takes priority - parameter has already been written
            next;
        }

        print {$WEBINJECT_CONFIG} "    $_indent<$_parameter>";
        print {$WEBINJECT_CONFIG} "$global_config->{$_section}->{$_parameter}";
        print {$WEBINJECT_CONFIG} "</$_parameter>\n";
    }

    if (not $_section eq 'main') {
        print {$WEBINJECT_CONFIG} "    </$_section>\n";
    }

    return;
}

#------------------------------------------------------------------
sub _write_webinject_wif_config {
    my ($_run_number) = @_;

    print {$WEBINJECT_CONFIG} "    <wif>\n";
    print {$WEBINJECT_CONFIG} "        <batch>$opt_batch</batch>\n";
    print {$WEBINJECT_CONFIG} "        <folder>$testfile_parent_folder_name</folder>\n";
    print {$WEBINJECT_CONFIG} "        <run_number>$_run_number</run_number>\n";
    print {$WEBINJECT_CONFIG} "    </wif>\n";

    return;
}
#------------------------------------------------------------------
sub get_web_server_location {

    my $_cmd = 'subs\get_web_server_location.pl';
    my $_server_location = `$_cmd`;
    #print {*STDOUT} "$server_location [$_server_location]\n";

    return $_server_location;
}

#------------------------------------------------------------------
sub create_temp_folder {
    my $_random = int rand 99_999;
    $_random = sprintf '%05d', $_random; # add some leading zeros

    my $_random_folder = $opt_target . '_' . $testfile_name . '_' . $_random;
    mkdir 'temp/' . $_random_folder or die "\n\nCould not create temporary folder temp/$_random_folder\n";

    return $_random_folder;
}

#------------------------------------------------------------------
sub remove_temp_folder {
    my ($_remove_folder, $_opt_keep) = @_;

    if (defined $_opt_keep) {
        # user has decided to keep temporary files
        print {*STDOUT} "\nKept temporary folder $_remove_folder\n";
        return;
    }

    #if (-e "temp/$_remove_folder") {
    #    unlink glob 'temp/' . $_remove_folder . q{/*} or die "Could not delete temporary files in folder temp/$_remove_folder\n";
    #}

    my $_max = 30;
    my $_try = 0;

    ATTEMPT:
    {
        eval
        {
            remove_tree 'temp/' . $_remove_folder or die "Could not remove temporary folder temp/$_remove_folder\n";
        };

        if ( $@ and $_try++ < $_max )
        {
            #print "\nError: $@ Failed to remove folder, trying again...\n";
            sleep 0.1;
            redo ATTEMPT;
        }
    }

    if ($@) {
        print {*STDOUT} "\nError: $@ Failed to remove folder temp/$_remove_folder after $_max tries\n\n";
    }

    return;
}

#------------------------------------------------------------------
sub _read_config {
    $config = Config::Tiny->read( 'wif.config' );

    # main
    $opt_target = $config->{main}->{target};
    $opt_batch = $config->{main}->{batch};
    $opt_environment = $config->{main}->{environment};
    $opt_use_browsermob_proxy = $config->{main}->{use_browsermob_proxy};
    $config_is_automation_controller = $config->{main}->{is_automation_controller};

    # path
    $testfile_full = $config->{path}->{testfile_full};
    $selenium_location_full = $config->{path}->{selenium_location_full};
    $web_server_location_full = $config->{path}->{web_server_location_full};
    $web_server_address = $config->{path}->{web_server_address};
    $webinject_location = $config->{path}->{webinject_location};
    $browsermob_proxy_location_full = $config->{path}->{browsermob_proxy_location_full};

    # normalise config
    if (lc $config_is_automation_controller eq 'true' ) {
        $config_is_automation_controller = 'true';
    } else {
        $config_is_automation_controller = 'false';
    }

    # normalise config
    if (lc $opt_use_browsermob_proxy eq 'true' ) {
        $opt_use_browsermob_proxy = 'true';
    } else {
        $opt_use_browsermob_proxy = 'false';
    }

    return;
}

#------------------------------------------------------------------
sub _write_config {

    my $_config = Config::Tiny->new;

    # main
    $config->{main}->{target} = $opt_target;
    $config->{main}->{batch} = $opt_batch;
    $config->{main}->{environment} = $opt_environment;
    $config->{main}->{use_browsermob_proxy} = $opt_use_browsermob_proxy;
    $config->{main}->{is_automation_controller} = $config_is_automation_controller;

    # path
    $config->{path}->{testfile_full} = $testfile_full;
    $config->{path}->{selenium_location_full} = $selenium_location_full;
    $config->{path}->{web_server_location_full} = $web_server_location_full;
    $config->{path}->{web_server_address} = $web_server_address;
    $config->{path}->{webinject_location} = $webinject_location;
    $config->{path}->{browsermob_proxy_location_full} = $browsermob_proxy_location_full;

    $config->write( 'wif.config' );

    return;
}

#------------------------------------------------------------------
sub get_options_and_config {  #shell options

    _read_config();

    # config file definition wins over hard coded defaults
    if (not defined $opt_environment) { $opt_environment = 'DEV'; }; # default the environment name
    if (not defined $opt_batch) { $opt_batch = 'Default_Batch'; }; # default the batch

    my $_opt_no_update_config;
    # options specified at the command line win over those defined in wif.config
    Getopt::Long::Configure('bundling');
    GetOptions(
        't|target=s'                => \$opt_target,
        'b|batch=s'                 => \$opt_batch,
        'e|env=s'                   => \$opt_environment,
        'p|use-browsermob-proxy=s'  => \$opt_use_browsermob_proxy,
        'n|no-retry'                => \$opt_no_retry,
        'u|no-update-config'        => \$_opt_no_update_config,
        'c|capture-stdout'          => \$opt_capture_stdout,
        'k|keep'                    => \$opt_keep,
        'v|V|version'               => \$opt_version,
        'h|help'                    => \$opt_help,
        )
        or do {
            print_usage();
            exit;
        };
    if ($opt_version) {
        print_version();
        exit;
    }

    if ($opt_help) {
        print_version();
        print_usage();
        exit;
    }

    # read the testfile name, and ensure it exists
    if (($#ARGV + 1) < 1) {
        if (not defined $testfile_full) {
            print {*STDOUT} "\nERROR: No test file name specified at command line or found in wif.config\n";
            print_usage();
            exit;
        }
    } else {
        $testfile_full = $ARGV[0];
    }
    ($testfile_name, $testfile_path) = fileparse($testfile_full,'.xml');

    my $_abs_testfile_full = File::Spec->rel2abs( $testfile_full );
    $testfile_parent_folder_name =  basename ( dirname($_abs_testfile_full) );
    # done like this in case we were told the test file is in "./" - we need the complete name for reporting purposes

    if (not -e $testfile_full) {
        die "\n\nERROR: no such test file found $testfile_full\n";
    }

    if (not defined $opt_target) {
        print {*STDOUT} "\n\nERROR: Target sub environment name must be specified\n";
        exit;
    }

    # now we know what the preferred settings are, save them for next time
    if ( not defined $_opt_no_update_config ) {
        _write_config();
    }

    return;
}

sub print_version {
    print {*STDOUT} "\nWebInjectFramework version $VERSION\nFor more info: https://github.com/Qarj/WebInjectFramework\n\n";
    return;
}

sub print_usage {
    print <<'EOB'

Usage: wif.pl tests\testfilename.xml <<options>>

-t|--target                 target environment handle           --target skynet
-b|--batch                  batch name for grouping results     --batch SmokeTests
-e|--env                    high level environment DEV, LIVE    --env DEV
-p|--use-browsermob-proxy   use browsermob-proxy                --use-browsermob-proxy true
-n|--no-retry               do not invoke retries
-u|--no-update-config       do not update config to reflect options
-c|--capture-stdout         capture wif.pl and webinject.pl STDOUT
-k|--keep                   keep temporary files

wif.pl -v|--version
wif.pl -h|--help
EOB
;
return;
}
#------------------------------------------------------------------
