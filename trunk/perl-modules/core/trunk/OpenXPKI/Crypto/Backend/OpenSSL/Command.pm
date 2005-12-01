## OpenXPKI::Crypto::Backend::OpenSSL::Command
## (C)opyright 2005 Michael Bell
## $Revision$

use strict;
use warnings;
use utf8;

use OpenXPKI::Crypto::Backend::OpenSSL::Command::create_random;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::create_key;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::create_pkcs10;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::create_cert;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::create_pkcs12;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::issue_cert;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::issue_crl;

use OpenXPKI::Crypto::Backend::OpenSSL::Command::convert_key;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::convert_pkcs10;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::convert_cert;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::convert_crl;

use OpenXPKI::Crypto::Backend::OpenSSL::Command::pkcs7_sign;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::pkcs7_encrypt;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::pkcs7_decrypt;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::pkcs7_verify;
use OpenXPKI::Crypto::Backend::OpenSSL::Command::pkcs7_get_chain;

package OpenXPKI::Crypto::Backend::OpenSSL::Command;

use OpenXPKI qw(debug read_file write_file);
use OpenXPKI::DN;
use Date::Parse;
use File::Temp;
use File::Spec;
use POSIX qw(strftime);
use OpenXPKI::Exception;
use English;

sub new
{
    my $that = shift;
    my $class = ref($that) || $that;
    my $self = { @_ };
    bless $self, $class;
    #$self->{DEBUG} = 1;

    ## re-organize engine stuff

    if (not exists $self->{ENGINE} or not ref $self->{ENGINE})
    {
        OpenXPKI::Exception->throw (
            message => "I18N_OPENXPKI_CRYPTO_OPENSSL_COMMAND_MISSING_ENGINE");
    }

    # determine temporary directory to use:
    # if a temporary directoy is specified, use it
    # else try /var/tmp (because potentially large files may be written that
    # are better left in the /var file system)
    # if /var/tmp does not exist fallback to /tmp

    my $requestedtmp = $self->{TMP};
    delete $self->{TMP};
  CHECKTMPDIRS:
    for my $path ($requestedtmp,                      # user's preference
		  File::Spec->catfile('var', 'tmp'),  # suitable for large files
		  File::Spec->catfile('tmp'),         # present on all UNIXes
	) {

	# directory must be readable & writable to be usable as tmp
	if (defined $path && 
	    (-d $path) &&
	    (-r $path) &&
	    (-w $path)) {
	    $self->{TMP} = $path;
	    last CHECKTMPDIRS;
	}
    }

    if (! (exists $self->{TMP} && -d $self->{TMP}))
    {
        OpenXPKI::Exception->throw (
            message => "I18N_OPENXPKI_CRYPTO_OPENSSL_TEMPORARY_DIRECTORY_UNAVAILABLE");
    }

    return $self;
}

sub set_tmpfile
{
    my $self = shift;
    my $keys = { @_ };

    foreach my $key (keys %{$keys})
    {
	push @{$self->{CLEANUP}->{FILE}}, $keys->{$key};

        $self->{$key."FILE"} = $keys->{$key};
    }
    return 1;
}

sub get_tmpfile
{
    my $self = shift;

    
    my $tmpdir = $self->{TMP} || File::Spec->catfile('tmp');
    my $template = File::Spec->catfile($tmpdir, "openxpkiXXXXXX");

    if (scalar(@_) == 0) {
	my ($fh, $filename) = File::Temp::mkstemp($template);
	if (! $fh) {
	    OpenXPKI::Exception->throw (
		message => "I18N_OPENXPKI_CRYPTO_OPENSSL_COMMAND_MAKE_TMPFILE_FAILED",
		params  => {"FILENAME" => $filename});
	}
	close $fh;
	chmod 0600, $filename;
	
	push @{$self->{CLEANUP}->{FILE}}, $filename;

	return $filename;
    }
    else
    {
	while (my $arg = shift) {
	    my ($fh, $filename) = File::Temp::mkstemp($template);
	    if (! $fh) {
		OpenXPKI::Exception->throw (
		    message => "I18N_OPENXPKI_CRYPTO_OPENSSL_COMMAND_MAKE_TMPFILE_FAILED",
		    params  => {"FILENAME" => $filename});
	    }
	    close $fh;
	    chmod 0600, $filename;

	    $self->set_tmpfile($arg => $filename);
	}
    }
}

sub set_env
{
    my $self = shift;
    my $keys = { @_ };

    foreach my $key (keys %{$keys})
    {
	push @{$self->{CLEANUP}->{ENV}}, $key;
        $ENV{$key} = $keys->{$key};
    }
    return 1;
}

sub cleanup
{
    my $self = shift;

    foreach my $file (@{$self->{CLEANUP}->{FILE}})
    {
        if (-e $file) 
	{
	    unlink $file;
	}
        if (-e $file)
        {
            OpenXPKI::Exception->throw (
                message => "I18N_OPENXPKI_CRYPTO_OPENSSL_COMMAND_CLEANUP_FILE_FAILED",
                params  => {"FILENAME" => $file});
        }
    }

    foreach my $variable (@{$self->{CLEANUP}->{ENV}})
    {
        delete $ENV{$variable};
        if (exists $ENV{$variable})
        {
            OpenXPKI::Exception->throw (
                message => "I18N_OPENXPKI_CRYPTO_OPENSSL_COMMAND_CLEANUP_ENV_FAILED",
                params  => {"VARIABLE" => $variable});
        }
    }

    return 1;
}

sub get_openssl_dn
{
    my $self = shift;
    my $dn   = shift;

    $self->debug ("rfc2253: $dn");
    my $dn_obj = OpenXPKI::DN->new ($dn);
    if (not $dn_obj) {
        OpenXPKI::Exception->throw (
            message => "I18N_OPENXPKI_CRYPTO_OPENSSL_COMMAND_DN_FAILURE",
            param   => {"DN" => $dn});
    }

    ## this is necessary because OpenSSL needs the utf8 bytes
    #pack/unpack is too slow, try to use "use utf8;"
    #$dn = pack "C*", unpack "C0U*", $dn_obj->get_openssl_dn ();
    $dn = $dn_obj->get_openssl_dn ();
    $self->debug ("OpenSSL X.500: $dn");

    return $dn;
}

sub get_config_variable
{
    my $self = shift;
    my $keys = { @_ };

    my $name     = $keys->{NAME};
    my $config   = $keys->{CONFIG};
    my $filename = $keys->{FILENAME};

    $config = $self->read_file ($filename)
        if (not $config);

    return "" if ($config !~ /^(.*\n)*\s*${name}\s*=\s*([^\n^#]+).*$/s);

    my $result = $config;
       $result =~ s/^(.*\n)*\s*${name}\s*=\s*([^\n^#]+).*$/$2/s;
       $result =~ s/[\r\n\s]*$//s;
    if ($result =~ /\$/)
    {
        my $dir = $result;
           $dir =~ s/^.*\$([a-zA-Z0-9_]+).*$/$1/s;
        my $value = $self->get_config_variable (NAME => $dir, CONFIG => $config);
        ## why we use this check?
        ## return undef if (not defined $dir);
        $result =~ s/\$$dir/$value/g;
    }
    return $result;
}

sub get_openssl_time
{
    my $self = shift;
    my $time = shift;

    $time = str2time ($time);
    $time = [ gmtime ($time) ];
    $time = POSIX::strftime ("%g%m%d%H%M%S",@{$time})."Z";

    return $time;
}

sub DESTROY
{
    my $self = shift;
    $self->cleanup();
}

1;
__END__

=head1 Description

This function is the base class for all available OpenSSL commands
from the OpenSSL command line interface. All commands are executed
inside of the OpenSSL shell.

=head1 Functions

=head2 new

is the constructor. The ENGINE and the TMP parameter must be always
present. All other parameters will be passed without any checks to
the hash of the class instance. The real checks must be implemented
by the commands itself.

=head2 set_tmpfile

expects a hash with prefix infront of FILE and the filename which is
a tmpfile. Example:

$self->set_tmpfile ("IN" => "/tmp/example.txt")

mapped to

$self->{INFILE} = "/tmp/example.txt";

All temporary file are cleaned up automatically.

=head2 get_tmpfile

If called without arguments this method creates a temporary file and 
returns its filename:

  my $tmpfile = $self->get_tmpfile();

If called with one or more arguments, the method creates a temporary
file for each argument specified and calls $self->set_tmpfile() for
this argument.

Calling

  $self->get_tmpfile(IN, OUT);

is equivalent to

  $self->set_tmpfile( IN  => $self->get_tmpfile(),
                      OUT => $self->get_tmpfile() );

All temporary file are set to mode 0600 and are cleaned up automatically.

=head2 set_env

This function works exactly like set_tmpfile but without any
automatical prefixes or suffixes. The environment is also
cleaned up automatically.

=head2 cleanup

performs the cleanup of any temporary stuff like files from
set_tmpfile and environment variables from set_env.

=head2 get_openssl_dn

expects a RFC2253 compliant DN and returns an OpenSSL DN.

=head2 get_openssl_time

expects a time string compliant with Date::Parse and returns
a timestring which is compliant with the format used in
index.txt.

=head2 get_config_variable

is used to find a configuration variable inside of an OpenSSL
configuration file. The parameters are the NAME of the configuration
parameter and the FILENAME of the file which contains the parameter
or the complete CONFIG itself.

The function is able to resolve any used variables inside of the
configuration. Defintions like $dir/certs are supported.
