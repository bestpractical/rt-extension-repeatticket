use warnings;
use strict;

package RT::Extension::RepeatTicket;

our $VERSION = "0.01";

use RT::Interface::Web;
use DateTime;
use RT::Date;
use List::MoreUtils qw/after/;
use DateTime::Event::ICal;

my $old_create_ticket = \&HTML::Mason::Commands::CreateTicket;
{
    no warnings 'redefine';

    *HTML::Mason::Commands::CreateTicket = sub {
        my %args = @_;
        my ( $ticket, @actions ) = $old_create_ticket->(@_);
        if ( $ticket && $args{'repeat-enabled'} ) {
            my ($attr) = SetRepeatAttribute(
                $ticket,
                'tickets'     => [ $ticket->id ],
                'last-ticket' => $ticket->id,
                map { $_ => $args{$_} } grep { /^repeat/ } keys %args
            );
            Run($attr);
        }
        return ( $ticket, @actions );
    };
}

sub SetRepeatAttribute {
    my $ticket = shift;
    return 0 unless $ticket;
    my %args        = @_;
    my %repeat_args = (
        'repeat-enabled'              => undef,
        'repeat-details-weekly-weeks' => undef,
        %args
    );

    my ($old_attr) = $ticket->Attributes->Named('RepeatTicketSettings');
    my %old;
    %old = %{ $old_attr->Content } if $old_attr;

    my $content = { %old, %repeat_args };

    $ticket->SetAttribute(
        Name    => 'RepeatTicketSettings',
        Content => $content,
    );

    my ($attr) = $ticket->Attributes->Named('RepeatTicketSettings');

    return ( $attr, $ticket->loc('Recurrence updated') );    # loc
}

use RT::Ticket;

sub Run {
    my $attr    = shift;
    my $content = $attr->Content;
    return unless $content->{'repeat-enabled'};

    my $checkday = shift
      || DateTime->today( time_zone => RT->Config->Get('Timezone') );
    my @ids = Repeat( $attr, $checkday );
    push @ids,
      MaybeRepeatMore($attr);    # create more to meet the coexistent number
    return @ids;
}

sub Repeat {
    my $attr      = shift;
    my @checkdays = @_;
    my @ids;

    my $content = $attr->Content;
    return unless $content->{'repeat-enabled'};

    my $repeat_ticket = $attr->Object;

    my $tickets_needed = TicketsToMeetCoexistentNumber($attr);
    return unless $tickets_needed;

    for my $checkday (@checkdays) {
        # Adjust by lead time
        my $original_date = $checkday->clone();
        $checkday = $checkday->add( days => $content->{'repeat-lead-time'} )
          if defined $content->{'repeat-lead-time'};
        $RT::Logger->debug( 'Checking date ' . $original_date ->ymd .
                            ' with adjusted lead time date ' . $checkday->ymd );

        if ( $content->{'repeat-start-date'} ) {
            my $date = RT::Date->new( RT->SystemUser );
            $date->Set(
                Format => 'unknown',
                Value  => $content->{'repeat-start-date'},
            );
            if ( $checkday->ymd lt $date->Date ) {
                $RT::Logger->debug('Not yet at start date' . $date->Date);
                next;
            }
        }

        if ( $content->{'repeat-end'} && $content->{'repeat-end'} eq 'number' )
        {
            if ( $content->{'repeat-end-number'} <=
                $content->{'repeat-occurrences'} )
            {
                $RT::Logger->debug('Failed repeat-end-number check');
                last;
            }
        }

        if ( $content->{'repeat-end'} && $content->{'repeat-end'} eq 'date' ) {
            my $date = RT::Date->new( RT->SystemUser );
            $date->Set(
                Format => 'unknown',
                Value  => $content->{'repeat-end-date'},
            );

            if ( $original_date->ymd gt $date->Date ) {
                $RT::Logger->debug('Failed repeat-end-date check');
                next;
            }
        }

        my $last_ticket = RT::Ticket->new( RT->SystemUser );
        $last_ticket->Load( $content->{'last-ticket'} );

        my $last_due;
        if ( $last_ticket->DueObj->Unix ) {
            $last_due = DateTime->from_epoch(
                epoch     => $last_ticket->DueObj->Unix,
                time_zone => RT->Config->Get('Timezone'),
            );
            $last_due->truncate( to => 'day' );
        }

        my $last_created = DateTime->from_epoch(
            epoch     => $last_ticket->CreatedObj->Unix,
            time_zone => RT->Config->Get('Timezone'),
        );
        $last_created->truncate( to => 'day' );
        next unless $last_created->ymd lt $checkday->ymd;

        my $set;
        if ( $content->{'repeat-type'} eq 'daily' ) {
            if ( $content->{'repeat-details-daily'} eq 'day' ) {
                my $span = $content->{'repeat-details-daily-day'} || 1;
                $set = DateTime::Event::ICal->recur(
                    dtstart => $last_due || $last_created,
                    freq => 'daily',
                    interval => $span,
                );
                next unless $set->contains($checkday);
            }
            elsif ( $content->{'repeat-details-daily'} eq 'weekday' ) {
                $set = DateTime::Event::ICal->recur(
                    dtstart => $last_due || $last_created,
                    freq => 'daily',
                    byday => [ 'mo', 'tu', 'we', 'th', 'fr' ],
                );
                next unless $set->contains($checkday);
            }
            elsif ( $content->{'repeat-details-daily'} eq 'complete' ) {
                unless ( CheckCompleteStatus($last_ticket) ) {
                    $RT::Logger->debug('Failed complete status check');
                    last;
                }

                unless (
                    CheckCompleteDate(
                        $checkday, $last_ticket, 'day',
                        $content->{'repeat-details-daily-complete'}
                    )
                  )
                {
                    $RT::Logger->debug('Failed complete date check');
                    next;
                }
            }

        }
        elsif ( $content->{'repeat-type'} eq 'weekly' ) {
            if ( $content->{'repeat-details-weekly'} eq 'week' ) {
                my $span = $content->{'repeat-details-weekly-week'} || 1;
                my $date = $checkday->clone;

                my $weeks = $content->{'repeat-details-weekly-weeks'};
                unless ( defined $weeks ) {
                    $RT::Logger->debug('Failed weeks defined check');
                    next;
                }

                $weeks = [$weeks] unless ref $weeks;

                $set = DateTime::Event::ICal->recur(
                    dtstart => $last_due || $last_created,
                    freq => 'weekly',
                    interval => $span,
                    byday    => $weeks,
                );

                next unless $set->contains($checkday);

            }
            elsif ( $content->{'repeat-details-weekly'} eq 'complete' ) {
                unless ( CheckCompleteStatus($last_ticket) ) {
                    $RT::Logger->debug('Failed complete status check');
                    last;
                }

                unless (
                    CheckCompleteDate(
                        $checkday, $last_ticket, 'week',
                        $content->{'repeat-details-weekly-complete'}
                    )
                  )
                {
                    $RT::Logger->debug('Failed complete date check');
                    next;
                }
            }
        }
        elsif ( $content->{'repeat-type'} eq 'monthly' ) {
            if ( $content->{'repeat-details-monthly'} eq 'day' ) {
                my $day  = $content->{'repeat-details-monthly-day-day'}   || 1;
                my $span = $content->{'repeat-details-monthly-day-month'} || 1;

                $set = DateTime::Event::ICal->recur(
                    dtstart => $last_due || $last_created,
                    freq => 'monthly',
                    interval   => $span,
                    bymonthday => $day,
                );

                next unless $set->contains($checkday);
            }
            elsif ( $content->{'repeat-details-monthly'} eq 'week' ) {
                my $day = $content->{'repeat-details-monthly-week-week'}
                  || 'mo';
                my $span = $content->{'repeat-details-monthly-week-month'} || 1;
                my $number = $content->{'repeat-details-monthly-week-number'}
                  || 1;

                $set = DateTime::Event::ICal->recur(
                    dtstart => $last_due || $last_created,
                    freq => 'monthly',
                    interval => $span,
                    byday    => $number . $day,
                );

                next unless $set->contains($checkday);
            }
            elsif ( $content->{'repeat-details-monthly'} eq 'complete' ) {
                unless ( CheckCompleteStatus($last_ticket) ) {
                    $RT::Logger->debug('Failed complete status check');
                    last;
                }

                unless (
                    CheckCompleteDate(
                        $checkday, $last_ticket, 'month',
                        $content->{'repeat-details-monthly-complete'}
                    )
                  )
                {
                    $RT::Logger->debug('Failed complete date check');
                    next;
                }
            }
        }
        elsif ( $content->{'repeat-type'} eq 'yearly' ) {
            if ( $content->{'repeat-details-yearly'} eq 'day' ) {
                my $day   = $content->{'repeat-details-yearly-day-day'}   || 1;
                my $month = $content->{'repeat-details-yearly-day-month'} || 1;
                $set = DateTime::Event::ICal->recur(
                    dtstart => $last_due || $last_created,
                    freq    => 'yearly',
                    bymonth => $month,
                    bymonthday => $day,
                );

                next unless $set->contains($checkday);
            }
            elsif ( $content->{'repeat-details-yearly'} eq 'week' ) {
                my $month = $content->{'repeat-details-yearly-week-month'} || 1;
                my $day = $content->{'repeat-details-yearly-week-week'} || 'mo';
                my $number = $content->{'repeat-details-yearly-week-number'}
                  || 1;
                $set = DateTime::Event::ICal->recur(
                    dtstart => $last_due || $last_created,
                    freq    => 'yearly',
                    bymonth => $month,
                    byday   => $number . $day,
                );

                next unless $set->contains($checkday);
            }
            elsif ( $content->{'repeat-details-yearly'} eq 'complete' ) {
                unless ( CheckCompleteStatus($last_ticket) ) {
                    $RT::Logger->debug('Failed complete status check');
                    last;
                }

                unless (
                    CheckCompleteDate(
                        $checkday, $last_ticket, 'year',
                        $content->{'repeat-details-yearly-complete'}
                    )
                  )
                {
                    $RT::Logger->debug('Failed complete date check');
                    next;
                }
            }
        }

        # use RT::Date to work around the timezone issue
        my $starts = RT::Date->new( RT->SystemUser );
        $starts->Set( Format => 'unknown', Value => $original_date->ymd );

        my $due;
        if ($set) {
            $due = RT::Date->new( RT->SystemUser );
            $due->Set( Format => 'unknown', Value => $checkday );
        }

        my ( $id, $txn, $msg ) = _RepeatTicket(
            $repeat_ticket,
            Starts => $starts->ISO,
            $due
            ? ( Due => $due->ISO )
            : (),
        );

        if ($id) {
            $RT::Logger->info(
                "Repeated ticket " . $repeat_ticket->id . ": $id" );
            $content->{'repeat-occurrences'}++;
            $content->{'last-ticket'} = $id;
            push @{ $content->{'tickets'} }, $id;
            push @ids, $id;
        }
        else {
            $RT::Logger->error( "Failed to repeat ticket for "
                  . $repeat_ticket->id
                  . ": $msg" );
            next;
        }
    }

    $attr->SetContent($content);
    return @ids;
}

sub TicketsToMeetCoexistentNumber {
    my $attr    = shift;
    my $content = $attr->Content;

    my $co_number = $content->{'repeat-coexistent-number'};
    $co_number = RT->Config->Get('RepeatTicketCoexistentNumber')
      unless defined $co_number && length $co_number;  # respect 0 but ''
    return unless $co_number;

    my $tickets = GetActiveTickets($content) || 0;
    return $co_number - @$tickets;
}

sub GetActiveTickets {
    my $content = shift;

    my $tickets_ref = $content->{tickets} || [];
    @$tickets_ref = grep {
        my $t = RT::Ticket->new( RT->SystemUser );
        $t->Load($_);
        !$t->QueueObj->Lifecycle->IsInactive( $t->Status );
    } @$tickets_ref;

    return $tickets_ref;
}

sub _RepeatTicket {
    my $repeat_ticket = shift;
    return unless $repeat_ticket;

    my %args = @_;
    my $cf   = RT::CustomField->new( RT->SystemUser );
    $cf->Load('Original Ticket');

    my $repeat = {
        Queue           => $repeat_ticket->Queue,
        Requestor       => join( ',', $repeat_ticket->RequestorAddresses ),
        Cc              => join( ',', $repeat_ticket->CcAddresses ),
        AdminCc         => join( ',', $repeat_ticket->AdminCcAddresses ),
        InitialPriority => $repeat_ticket->Priority,
        'CustomField-' . $cf->id => $repeat_ticket->id,
    };

    $repeat->{$_} = $repeat_ticket->$_()
      for qw/Owner Subject FinalPriority TimeEstimated/;

    my $members = $repeat_ticket->Members;
    my ( @members, @members_of, @refers, @refers_by, @depends, @depends_by );
    my $refers         = $repeat_ticket->RefersTo;
    my $get_link_value = sub {
        my ( $link, $type ) = @_;
        my $uri_method   = $type . 'URI';
        my $local_method = 'Local' . $type;
        my $uri          = $link->$uri_method;
        return
          if $uri->IsLocal
              and $uri->Object
              and $uri->Object->isa('RT::Ticket')
              and $uri->Object->Type eq 'reminder';

        return $link->$local_method || $uri->URI;
    };
    while ( my $refer = $refers->Next ) {
        my $refer_value = $get_link_value->( $refer, 'Target' );
        push @refers, $refer_value if defined $refer_value;
    }
    $repeat->{'new-RefersTo'} = join ' ', @refers;

    my $refers_by = $repeat_ticket->ReferredToBy;
    while ( my $refer_by = $refers_by->Next ) {
        my $refer_by_value = $get_link_value->( $refer_by, 'Base' );
        push @refers_by, $refer_by_value if defined $refer_by_value;
    }
    $repeat->{'RefersTo-new'} = join ' ', @refers_by;

    my $cfs = $repeat_ticket->QueueObj->TicketCustomFields();
    while ( my $cf = $cfs->Next ) {
        my $cf_id     = $cf->id;
        my $cf_values = $repeat_ticket->CustomFieldValues( $cf->id );
        my @cf_values;
        while ( my $cf_value = $cf_values->Next ) {
            push @cf_values, $cf_value->Content;
        }
        $repeat->{"Object-RT::Ticket--CustomField-$cf_id-Value"} = join "\n",
          @cf_values;
    }

    $repeat->{Status} = 'new';

    for ( keys %$repeat ) {
        $args{$_} = $repeat->{$_} if not defined $args{$_};
    }

    my $txns = $repeat_ticket->Transactions;
    $txns->Limit( FIELD => 'Type', VALUE => 'Create' );
    $txns->OrderBy( FIELD => 'id', ORDER => 'ASC' );
    $txns->RowsPerPage(1);
    my $txn  = $txns->First;
    my $atts = RT::Attachments->new( RT->SystemUser );
    $atts->OrderBy( FIELD => 'id', ORDER => 'ASC' );
    $atts->Limit( FIELD => 'TransactionId', VALUE => $txn->id );
    $atts->Limit( FIELD => 'Parent',        VALUE => 0 );
    my $top = $atts->First;

    # XXX no idea why this doesn't work:
    # $args{MIMEObj} = $top->ContentAsMIME( Children => 1 ) );

    my $parser = RT::EmailParser->new( RT->SystemUser );
    $args{MIMEObj} =
      $parser->ParseMIMEEntityFromScalar(
        $top->ContentAsMIME( Children => 1 )->as_string );

    my $ticket = RT::Ticket->new( $repeat_ticket->CurrentUser );
    return $ticket->Create(%args);
}

sub MaybeRepeatMore {
    my $attr    = shift;
    my $content = $attr->Content;
    my $tickets_needed = TicketsToMeetCoexistentNumber($attr);

    my $last_ticket = RT::Ticket->new( RT->SystemUser );
    $last_ticket->Load( $content->{'last-ticket'} );

    my $last_due;
    if ( $last_ticket->DueObj->Unix ) {
        $last_due = DateTime->from_epoch(
            epoch     => $last_ticket->DueObj->Unix,
            time_zone => RT->Config->Get('Timezone'),
        );
        $last_due->truncate( to => 'day' );
    }

    my $last_created = DateTime->from_epoch(
        epoch     => $last_ticket->CreatedObj->Unix,
        time_zone => RT->Config->Get('Timezone'),
    );
    $last_created->truncate( to => 'day' );

    $content->{tickets} = GetActiveTickets($content);
    $attr->SetContent($content);

    my @ids;
    if ( $tickets_needed ) {
        my $set;
        if ( $content->{'repeat-type'} eq 'daily' ) {
            if ( $content->{'repeat-details-daily'} eq 'day' ) {
                $set = DateTime::Event::ICal->recur(
                    dtstart  => $last_due || $last_created,
                    freq     => 'daily',
                    interval => $content->{'repeat-details-daily-day'} || 1,
                );
            }
            elsif ( $content->{'repeat-details-daily'} eq 'weekday' ) {
                $set = DateTime::Event::ICal->recur(
                    dtstart  => $last_due || $last_created,
                    freq    => 'daily',
                    byday   => [ 'mo', 'tu', 'we', 'th', 'fr' ],
                );
            }
        }
        elsif ( $content->{'repeat-type'} eq 'weekly' ) {
            if ( $content->{'repeat-details-weekly'} eq 'week' ) {
                my $weeks = $content->{'repeat-details-weekly-weeks'};
                if ( defined $weeks ) {
                    $set = DateTime::Event::ICal->recur(
                        dtstart  => $last_due || $last_created,
                        freq     => 'weekly',
                        interval => $content->{'repeat-details-weekly-week'}
                          || 1,
                        byday => ref $weeks ? $weeks : [$weeks],
                    );
                }
                else {
                    $RT::Logger->error('No weeks defined');
                }
            }
        }
        elsif ( $content->{'repeat-type'} eq 'monthly' ) {
            if ( $content->{'repeat-details-monthly'} eq 'day' ) {
                $set = DateTime::Event::ICal->recur(
                    dtstart  => $last_due || $last_created,
                    freq     => 'monthly',
                    interval => $content->{'repeat-details-monthly-day-month'}
                      || 1,
                    bymonthday => $content->{'repeat-details-monthly-day-day'}
                      || 1,
                );
            }
            elsif ( $content->{'repeat-details-monthly'} eq 'week' ) {
                my $number = $content->{'repeat-details-monthly-week-number'}
                  || 1;
                my $day = $content->{'repeat-details-monthly-week-week'}
                  || 'mo';

                $set = DateTime::Event::ICal->recur(
                    dtstart  => $last_due || $last_created,
                    freq     => 'monthly',
                    interval => $content->{'repeat-details-monthly-week-month'}
                      || 1,
                    byday => $number . $day,
                );
            }
        }
        elsif ( $content->{'repeat-type'} eq 'yearly' ) {
            if ( $content->{'repeat-details-yearly'} eq 'day' ) {
                $set = DateTime::Event::ICal->recur(
                    dtstart  => $last_due || $last_created,
                    freq    => 'yearly',
                    bymonth => $content->{'repeat-details-yearly-day-month'}
                      || 1,
                    bymonthday => $content->{'repeat-details-yearly-day-day'}
                      || 1,
                );
            }
            elsif ( $content->{'repeat-details-yearly'} eq 'week' ) {
                my $number = $content->{'repeat-details-yearly-week-number'}
                  || 1;
                my $day = $content->{'repeat-details-yearly-week-week'} || 'mo';

                $set = DateTime::Event::ICal->recur(
                    dtstart  => $last_due || $last_created,
                    freq    => 'yearly',
                    bymonth => $content->{'repeat-details-yearly-week-month'}
                      || 1,
                    byday => $number . $day,
                );
            }
        }

        if ($set) {
            my @dates;
            my $iter = $set->iterator;
            while ( my $dt = $iter->next ) {
                next if $dt == $last_created;

                push @dates, $dt;
                last if @dates >= $tickets_needed;
            }

            for my $date (@dates) {
                push @ids, Repeat( $attr, @dates );
            }
        }
    }
    return @ids;
}

sub CheckCompleteStatus {
    my $ticket = shift;
    return 1 if $ticket->QueueObj->Lifecycle->IsInactive( $ticket->Status );
    return 0;
}

sub CheckCompleteDate {
    my $checkday = shift;
    my $ticket   = shift;
    my $type     = shift || 'day';
    my $span     = shift;
    $span = 1 unless defined $span;

    my $resolved = $ticket->ResolvedObj;
    my $date     = $checkday->clone;
    if ($span) {
        $date->subtract( "${type}s" => $span );
    }

    return 0
      if $resolved->Date( Timezone => 'user' ) gt $date->ymd;


    return 1;
}

1;
__END__

=head1 NAME

RT::Extension::RepeatTicket - Repeat tickets based on schedule

=head1 VERSION

Version 0.01

=head1 INSTALLATION

To install this module, run the following commands:

    perl Makefile.PL
    make
    make install
    make initdb

add RT::Extension::RepeatTicket to @Plugins in RT's etc/RT_SiteConfig.pm:

    Set( @Plugins, qw(... RT::Extension::RepeatTicket) );
    Set( $RepeatTicketCoexistentNumber, 1 );

C<$RepeatTicketCoexistentNumber> only works for repeats that don't rely on the
completion of previous tickets, in which case the config will be simply
ignored.

add bin/rt-repeat-ticket to the daily cron job.

=head1 Methods

=head2 Run( RT::Attribute $attr, DateTime $checkday )

Repeat the ticket if C<$checkday> meets the repeat settings.
It also tries to repeat more to meet config C<RepeatTicketCoexistentNumber>.

Return ids of new created tickets.

=head2 Repeat ( RT::Attribute $attr, DateTime $checkday_1, DateTime $checkday_2, ... )

Repeat the ticket for the check days that meet repeat settings.

Return ids of new created tickets.

=head2 MaybeRepeatMore ( RT::Attribute $attr )

Try to repeat more tickets to meet the coexistent ticket number.

Return ids of new created tickets.

=head2 SetRepeatAttribute ( RT::Ticket $ticket, %args )

Save %args to the ticket's "RepeatTicketSettings" attribute.

Return ( RT::Attribute, UPDATE MESSAGE )

=head1 AUTHOR

sunnavy, <sunnavy at bestpractical.com>


=head1 LICENSE AND COPYRIGHT

Copyright 2012 Best Practical Solutions, LLC.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


