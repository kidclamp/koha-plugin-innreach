package Koha::Plugin::Com::Theke::INNReach::Contribution;

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

use HTTP::Request::Common qw{ POST DELETE };
use MARC::Record;
use MARC::File::XML;
use MIME::Base64 qw{ encode_base64url };
use Try::Tiny;

use Koha::Biblios;
use Koha::Biblio::Metadatas;

use Koha::Plugin::Com::Theke::INNReach;
use Koha::Plugin::Com::Theke::INNReach::OAuth2;

use Data::Printer colored => 1;

use base qw(Class::Accessor);

__PACKAGE__->mk_accessors(qw( oauth2 config ));

=head1 Koha::Plugin::Com::Theke::INNReach::Contribution

A class implementing required methods for data contribution to the 
configured D2IR Central server.

=head2 Class methods

=head3 new

Class constructor

=cut

sub new {
    my ($class) = @_;

    my $args;

    $args->{config} = Koha::Plugin::Com::Theke::INNReach->new()->configuration;
    $args->{oauth}  = Koha::Plugin::Com::Theke::INNReach::OAuth2->new(
        {   client_id     => $args->{config}->{client_id},
            client_secret => $args->{config}->{client_secret}
        }
    );

    my $self = $class->SUPER::new($args);

    bless $self, $class;
    return $self;
}

=head3 contribute_bib

    my $res = $contribution->contribute_bib({ bibId => $bibId, [ centralServer => $centralServer ] });

By default it sends the MARC record and the required metadata
to all Central servers. If a centralServer parameter is passed,
then data is sent only to the specified one.

POST /innreach/v2/contribution/bib/<bibId>

=cut

sub contribute_bib {
    my ($self, $args) = @_;

    my $bibId = $args->{bibId};
    die "bibId is mandatory" unless $bibId;

    my ( $biblio, $metadata, $record );

    try {
        $biblio   = Koha::Biblios->find( $bibId );
        $metadata = Koha::Biblio::Metadatas->find(
            { biblionumber => $bibId,
              format       => 'marcxml',
              marcflavour  => 'marc21'
            }
        );
        $record = eval {
            MARC::Record::new_from_xml( $metadata->metadata, 'utf-8', $metadata->marcflavour );
        };
    }
    catch {
        die "Problem with requested biblio ($bibId)";
    };

    # Got the biblio, POST it
    my $suppress = 'n'; # expected default

    # delete all local fields ("Omit 9XX fields" rule)
    my @local = $record->field('9..');
    $record->delete_fields(@local);
    # Encode ISO2709 record
    my $encoded_record = encode_base64url( $record->as_usmarc );

    my $data = {
        marc21BibFormat => 'ISO2709', # Only supported value
        marc21BibData   => $encoded_record,
        titleHoldCount  => $biblio->holds->count,
        itemCount       => $biblio->items->count,
        suppress        => $suppress
    };

    my @central_servers;
    if ( $args->{centralServer} ) {
        push @central_servers, $args->{centralServer};
    }
    else {
        @central_servers = @{ $self->config->{centralServers} };
    }

    for my $central_server (@central_servers) {
        my $request = $self->post_request(
            {   endpoint    => '/innreach/v2/contribution/bib/' . $bibId,
                centralCode => $central_server,
                data        => $data
            }
        );
    }
}

=head3 contribute_batch_items

    my $res = $contribution->contribute_batch_items(
        {   bibId => $bibId,
            items => $items,
            [ centralServer => $centralServer ]
        }
    );

Sends item information (for adding or modifying) to the central server(s). the
I<bibId> and I<items> params are mandatory. I<items> has to be a Koha::Items iterator
and they all need to belong to the biblio identified by bibId.

POST /innreach/v2/contribution/items/<bibId>

=cut

sub contribute_batch_items {
    my ($self, $args) = @_;

    my $bibId = $args->{bibId};
    die "bibId is mandatory" unless $bibId;

    my $biblio = Koha::Biblios->find( $bibId );
    unless ( $biblio ) {
        die "Biblio not found ($bibId)";
    }

    my @itemInfo;

    while ( my $item = $items->next ) {
        unless ( $item->biblionumber == $bibId ) {
            die "Item (" . $item->itemnumber . ") doesn't belong to bib record ($bibId)";
        }

        my $itemCircStatus = "Available"; # TODO: Available/Not Available/On Loan/Non-Lendable

        my $itemInfo = {
            itemId            => $item->itemnumber,
            agencyCode        => $self->config->{library_to_agency}->{$item->homebranch},
            centralItemType   => $self->config->{local_to_central_itype}->{$item->effective_itemtype},
            locationKey       => lc( $item->homebranch ),
            itemCircStatus    => $itemCircStatus,
            holdCount         => $item->current_holds->count,
            dueDateTime       => ($item->onloan) ? dt_from_string( $item->onloan )->epoch : undef,
            callNumber        => $item->itemcallnumber,
            volumeDesignation => undef, # TODO
            copyNumber        => undef, # TODO
          # marc856URI        => undef, # We really don't have this concept in Koha
          # marc856PublicNote => undef, # We really don't have this concept in Koha
            itemNote          => $item->itemnotes,
            suppress          => 'n' # TODO: revisit
        }

        push @itemInfo, $iteminfo;
    }

    my @central_servers;
    if ( $args->{centralServer} ) {
        push @central_servers, $args->{centralServer};
    }
    else {
        @central_servers = @{ $self->config->{centralServers} };
    }

    for my $central_server (@central_servers) {
        my $request = $self->post_request(
            {   endpoint    => '/innreach/v2/contribution/items/' . $bibId,
                centralCode => $central_server,
                data        => { itemInfo => \@itemInfo }
            }
        );
    }
}

=head3 decontribute_bib

    my $res = $contribution->decontribute_bib(
        {   bibId => $bibId,
            [ centralServer => $centralServer ]
        }
    );

Makes an API request to INN-Reach central server(s) to decontribute the specified record.

DELETE /innreach/v2/contribution/bib/<bibId>

=cut

sub decontribute_bib {
    my ($self, $args) = @_;

    my $bibId = $args->{bibId};
    die "bibId is mandatory" unless $bibId;

    my @central_servers;
    if ( $args->{centralServer} ) {
        push @central_servers, $args->{centralServer};
    }
    else {
        @central_servers = @{ $self->config->{centralServers} };
    }

    for my $central_server (@central_servers) {
        my $request = $self->delete_request(
            {   endpoint    => '/innreach/v2/contribution/bib/' . $bibId,
                centralCode => $central_server
            }
        );
    }
}

=head3 update_bib_status

    my $res = $contribution->update_bib_status({ bibId => $bibId, [ centralServer => $centralServer ] });

It sends updated bib status to the central server(s).

POST /innreach/v2/contribution/bibstatus/<bibId>

=cut

sub update_bib_status {
    my ($self, $args) = @_;

    my $bibId = $args->{bibId};
    die "bibId is mandatory" unless $bibId;

    my ( $biblio, $metadata, $record );

    try {
        $biblio   = Koha::Biblios->find( $bibId );
        my $data = {
            titleHoldCount  => $biblio->holds->count,
            itemCount       => $biblio->items->count,
        };

        my @central_servers;
        if ( $args->{centralServer} ) {
            push @central_servers, $args->{centralServer};
        }
        else {
            @central_servers = @{ $self->config->{centralServers} };
        }

        for my $central_server (@central_servers) {
            my $request = $self->post_request(
                {   endpoint    => '/innreach/v2/contribution/bibstatus/' . $bibId,
                    centralCode => $central_server,
                    data        => $data
                }
            );
        }
    }
    catch {
        die "Problem with requested biblio ($bibId)";
    };
}

=head2 Internal methods

=head3 token

Method for retrieving a valid access token

=cut

sub token {
    my ($self) = @_;

    return $self->oauth2->get_token;
}

=head3 post_request

Generic request for POST

=cut

sub post_request {
    my ($self, $args) = @_;

    return POST(
        $self->config->{api_base_url} . '/' . $args->{endpoint},
        Authorization => "Bearer " . $self->token,
        'X-From-Code' => $self->config->{localServerCode},
        'X-To-Code'   => $args->{centralCode},
        Accept        => "application/json",,
        ContentType   => "application/x-www-form-urlencoded",
        Content       => $args->{data}
    );
}

=head3 delete_request

Generic request for DELETE

=cut

sub delete_request {
    my ($self, $args) = @_;

    return DELETE(
        $self->config->{api_base_url} . '/' . $args->{endpoint},
        Authorization => "Bearer " . $self->token,
        'X-From-Code' => $self->config->{localServerCode},
        'X-To-Code'   => $args->{centralCode},
        Accept        => "application/json",
    );
}

1;
