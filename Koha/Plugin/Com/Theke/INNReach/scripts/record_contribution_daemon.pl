#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use Getopt::Long;
use Pod::Usage;
use Try::Tiny;

use C4::Context;

use Koha::Plugin::Com::Theke::INNReach;
use Koha::Plugin::Com::Theke::INNReach::Contribution;

my $daemon_sleep    = 5;
my $verbose_logging = 0;
my $help       = 0;

my $result = GetOptions(
    'help|?'  => \$help,
    'v'       => \$verbose_logging,
    'sleep=s' => \$daemon_sleep,
);

if (not $result or $help) {
    pod2usage(1);
}

my $dbh;

while (1) {
    try {

        my $contribution = Koha::Plugin::Com::Theke::INNReach::Contribution->new;
        run_queued_tasks({ contribution => $contribution });

    }
    catch {
        if ($@ && $verbose_logging) {
            warn "Warning : $@\n";
        }
    };

    sleep $daemon_sleep;
}

=head3 run_queued_tasks

=cut

sub run_queued_tasks {
    my ($args) = @_;

    my $contribution = $args->{contribution};

    my $dbh = C4::Context->dbh;

    my $plugin = Koha::Plugin::Com::Theke::INNReach->new;
    my $table  = $plugin->get_qualified_table_name('task_queue');

    my $query = $dbh->prepare(qq{
        SELECT
            id,
            object_type,
            object_id,
            action,
            attempts,
            timestamp
        FROM
            $table
        WHERE
            status='queued' OR
            status='retry'
    });

    $query->execute;
    while ( my $task = $query->fetchrow_hashref ) {
        do_task({ task => $task, contribution => $contribution });
    }
}

=head3 do_task

=cut

sub do_task {
    my ($args) = @_;

    my $contribution = $args->{contribution};
    my $task         = $args->{task};
    die unless $task;

    my $object_type = $task->{object_type};
    my $object_id   = $task->{object_id};
    my $action      = $task->{action};

    if ( $object_type eq 'biblio' ) {
        if ( $action eq 'create' ) {
            do_biblio_create({ biblio_id => $object_id, contribution => $contribution, task => $task });
        }
        elsif ( $action eq 'modify' ) {
            do_biblio_modify({ biblio_id => $object_id, contribution => $contribution, task => $task });
        }
        elsif ( $action eq 'delete' ) {
            do_biblio_delete({ biblio_id => $object_id, contribution => $contribution, task => $task });
        }
    }
    elsif ( $object_type eq 'item' ) {
        if ( $action eq 'create' ) {
            do_item_create({ item_id => $object_id, contribution => $contribution, task => $task });
        }
        elsif ( $action eq 'modify' ) {
            do_item_modify({ item_id => $object_id, contribution => $contribution, task => $task });
        }
        elsif ( $action eq 'delete' ) {
            do_item_delete({ item_id => $object_id, contribution => $contribution, task => $task });
        }
    }
    else {
        warn "Unhandled object_type: $object_type";
    }
}

=head3 do_biblio_create

=cut

sub do_biblio_create {
    my ($args) = @_;

    my $biblio_id    = $args->{biblio_id};
    my $contribution = $args->{contribution};
    my $task         = $args->{task};

    try {
        my @result = $contribution->contribute_bib({ bibId => $biblio_id });
        if ( @result ) {
            if ( $task->{attempts} <= $contribution->config->{contribution}->{max_retries} // 10 ) {
                mark_task({ task => $task, status => 'retry' });
            }
            else {
                mark_task({ task => $task, status => 'error' });
            }
        }
        else {
            mark_task({ task => $task, status => 'success' });
        }
    }
    catch {
        die "$_";
    };

    return 1;
}

=head3 do_biblio_modify

=cut

sub do_biblio_modify {
    my ($args) = @_;

    my $biblio_id    = $args->{biblio_id};
    my $contribution = $args->{contribution};
    my $task         = $args->{task};

    try {
        my @result = $contribution->contribute_bib({ bibId => $biblio_id });
        if ( @result ) {
            if ( $task->{attempts} <= $contribution->config->{contribution}->{max_retries} // 10 ) {
                mark_task({ task => $task, status => 'retry' });
            }
            else {
                mark_task({ task => $task, status => 'error' });
            }
        }
        else {
            mark_task({ task => $task, status => 'success' });
        }
    }
    catch {
        die "$_";
    };

    return 1;
}

=head3 do_biblio_delete

=cut

sub do_biblio_delete {
    my ($args) = @_;

    my $biblio_id    = $args->{biblio_id};
    my $contribution = $args->{contribution};
    my $task         = $args->{task};

    try {
        my @result = $contribution->decontribute_bib({ bibId => $biblio_id });
        if ( @result ) {
            if ( $task->{attempts} <= $contribution->config->{contribution}->{max_retries} // 10 ) {
                mark_task({ task => $task, status => 'retry' });
            }
            else {
                mark_task({ task => $task, status => 'error' });
            }
        }
        else {
            mark_task({ task => $task, status => 'success' });
        }
    }
    catch {
        die "$_";
    };

    return 1;
}

=head3 do_item_create

=cut

sub do_item_create {
    my ($args) = @_;

    my $item_id      = $args->{item_id};
    my $contribution = $args->{contribution};
    my $task         = $args->{task};

    my $item = Koha::Items->find( $item_id );
    my $biblio_id = $item->biblionumber;

    try {
        my @result = $contribution->contribute_batch_items({ item => $item, bibId => $biblio_id });
        if ( @result ) {
            if ( $task->{attempts} <= $contribution->config->{contribution}->{max_retries} // 10 ) {
                mark_task({ task => $task, status => 'retry' });
            }
            else {
                mark_task({ task => $task, status => 'error' });
            }
        }
        else {
            mark_task({ task => $task, status => 'success' });
        }
    }
    catch {
        warn "$_";
    };

    return 1;
}

=head3 do_item_modify

=cut

sub do_item_modify {
    my ($args) = @_;

    my $item_id      = $args->{item_id};
    my $contribution = $args->{contribution};
    my $task         = $args->{task};

    my $item = Koha::Items->find( $item_id );
    my $biblio_id = $item->biblionumber;

    try {
        my @result = $contribution->contribute_batch_items({ item => $item, bibId => $biblio_id });
        if ( @result ) {
            if ( $task->{attempts} <= $contribution->config->{contribution}->{max_retries} // 10 ) {
                mark_task({ task => $task, status => 'retry' });
            }
            else {
                mark_task({ task => $task, status => 'error' });
            }
        }
        else {
            mark_task({ task => $task, status => 'success' });
        }
    }
    catch {
        die "$_";
    };

    return 1;
}

=head3 do_item_delete

=cut

sub do_item_delete {
    my ($args) = @_;

    my $item_id      = $args->{item_id};
    my $contribution = $args->{contribution};
    my $task         = $args->{task};

    try {
        my @result = $contribution->decontribute_item({ itemId => $item_id });
        if ( @result ) {
            if ( $task->{attempts} <= $contribution->config->{contribution}->{max_retries} // 10 ) {
                mark_task({ task => $task, status => 'retry' });
            }
            else {
                mark_task({ task => $task, status => 'error' });
            }
        }
        else {
            mark_task({ task => $task, status => 'success' });
        }
    }
    catch {
        die "$_";
    };

    return 1;
}

sub mark_task {
    my ($args)   = @_;
    my $task     = $args->{task};
    my $status   = $args->{status};
    my $task_id  = $task->{id};
    my $attempts = $task->{attempts};

    my $dbh = C4::Context->dbh;

    my $plugin = Koha::Plugin::Com::Theke::INNReach->new;
    my $table  = $plugin->get_qualified_table_name('task_queue');

    $attempts++ if $status eq 'retry';

    my $query = $dbh->prepare(qq{
        UPDATE
            $table
        SET
            status='$status',
            attempts=$attempts
        WHERE
            id=$task_id
    });

    $query->execute;
}

=head1 NAME

record_contribution_daemon.pl

=head1 SYNOPSIS

record_contribution_daemon.pl -s 5

 Options:
   -?|--help        brief help message
   -v               Be verbose
   --sleep N        Polling frecquency

=head1 OPTIONS

=over 8

=item B<--help|-?>

Print a brief help message and exits

=item B<-v>

Be verbose

=item B<--sleep N>

Use I<N> as the database polling frecquency.

=back

=head1 DESCRIPTION

A task queue processor daemon that takes care of updating INN-Reach central's server information
on catalog changes (both bibliographic records and holdings information).

=cut
