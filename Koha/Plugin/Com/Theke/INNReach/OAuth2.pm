package Koha::Plugin::Com::Theke::INNReach::OAuth2;

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# This program comes with ABSOLUTELY NO WARRANTY;

use Modern::Perl;

use base qw(Class::Accessor);

__PACKAGE__->mk_accessors(qw( ua ));

use DateTime;
use HTTP::Request::Common qw{ POST };
use JSON;
use LWP::UserAgent;
use MIME::Base64 qw{ decode_base64url encode_base64url };

use Exception::Class (
  'INNReach::OAuth2Error',
  'INNReach::OAuth2Error::MissingClientID'  => { isa => 'INNReach::OAuth2Error' },
  'INNReach::OAuth2Error::MissingClientCredentials'  => { isa => 'INNReach::OAuth2Error' },
);

sub new {
    my ($class, $args) = @_;

    my $client_id     = $args->{client_id};
    unless ($client_id) {
        INNReach::OAuth2Error::MissingClientID->throw();
    }

    my $client_secret = $args->{client_secret};
    unless ($client_id) {
        INNReach::OAuth2Error::MissingClientCredentials->throw();
    }

    my $credentials = encode_base64url( "$client_id:$client_secret" );

    my $self = $class->SUPER::new($args);
    $self->{token_endpoint} = "https://rssandbox-api.iii.com/auth/v1/oauth2/token";
    $self->{ua}          = LWP::UserAgent->new();
    $self->{scope}       = "innreach_tp";
    $self->{grant_type}  = 'client_credentials';
    $self->{credentials} = $credentials;
    $self->{request}     = POST(
        $self->{token_endpoint},
        Authorization => "Basic $credentials",
        Accept        => "application/json",,
        ContentType   => "application/x-www-form-urlencoded",
        Content       =>
        [
            grant_type => 'client_credentials',
            scope      => $self->{scope},
            undefined  => undef,
        ]
    );

    bless $self, $class;
    return $self;
}

sub get_token {
    my ($self) = @_;

    my $ua      = $self->{ua};
    my $request = $self->{request};

    my $response = decode_json( $ua->request($request)->decoded_content );
    $self->{access_token} = $response->{access_token};
    $self->{expiration}   = DateTime->now()->add( seconds => $response->{expires_in} );

    return $self;
}

sub is_token_expired {
    my ($self) = @_;

    return $self->{expiration} < DateTime->now();
}

1;
