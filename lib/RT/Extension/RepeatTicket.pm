use warnings;
use strict;

package RT::Extension::RepeatTicket;

our $VERSION = "0.01";

use RT::Interface::Web;
use DateTime;
use RT::Date;
use List::MoreUtils qw/after/;

my $old_create_ticket = \&HTML::Mason::Commands::CreateTicket;
{
    no warnings 'redefine';

    *HTML::Mason::Commands::CreateTicket = sub {
        my %args = @_;
        my ( $ticket, @actions ) = $old_create_ticket->(@_);
        if ( $ticket && $args{'repeat-enabled'} ) {
            my ($attr) = SetRepeatAttribute(
                $ticket,
                'tickets' => [ $ticket->id ],
                'last-ticket' => $ticket->id,
                map { $_ => $args{$_} } grep { /^repeat/ } keys %args
            );
            MaybeRepeatMore( $attr );
        }
        return ( $ticket, @actions );
    };
}

sub SetRepeatAttribute {
    my $ticket = shift;
    return 0 unless $ticket;
    my %args = @_;
    my %repeat_args = (
        'repeat-enabled'              => undef,
        'repeat-details-weekly-weeks' => undef,
         %args
    );

    my ( $old_attr ) = $ticket->Attributes->Named('RepeatTicketSettings');
    my %old;
    %old = %{$old_attr->Content} if $old_attr;

    my $content = { %old, %repeat_args };

    $ticket->SetAttribute(
        Name    => 'RepeatTicketSettings',
        Content => $content,
    );

    my ( $attr ) = $ticket->Attributes->Named('RepeatTicketSettings');

    return ( $attr, $ticket->loc('Recurrence updated') );    # loc
}

use RT::Ticket;

sub Run {
    my $attr = shift;
    my $content = $attr->Content;
    return unless $content->{'repeat-enabled'};

    my $checkday = shift
      || DateTime->today( time_zone => RT->Config->Get('Timezone') );
    my @ids = Repeat( $attr, $checkday );
    push @ids, MaybeRepeatMore( $attr ); # create more to meet the coexistent number
    return @ids;
}

sub Repeat {
    my $attr = shift;
    my @checkdays = @_;
    my @ids;

    my $content = $attr->Content;
    return unless $content->{'repeat-enabled'};

    my $repeat_ticket = $attr->Object;

    for my $checkday (@checkdays) {
        $RT::Logger->debug( 'checking ' . $checkday->ymd );

        if ( $content->{'repeat-start-date'} ) {
            my $date = RT::Date->new( RT->SystemUser );
            $date->Set(
                Format => 'unknown',
                Value  => $content->{'repeat-start-date'},
            );
            if ( $checkday->ymd lt $date->Date ) {
                $RT::Logger->debug( 'Failed repeat-start-date check' );
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

            if ( $checkday->ymd gt $date->Date ) {
                $RT::Logger->debug( 'Failed repeat-end-date check' );
                next;
            }
        }

        my $last_ticket = RT::Ticket->new( RT->SystemUser );
        $last_ticket->Load( $content->{'last-ticket'} );

        my $due_date = $checkday->clone;

        if ( $content->{'repeat-type'} eq 'daily' ) {
            if ( $content->{'repeat-details-daily'} eq 'day' ) {
                my $span = $content->{'repeat-details-daily-day'} || 1;
                my $date = $checkday->clone;

                unless ( CheckLastTicket( $date, $last_ticket, 'day', $span ) ) {
                    $RT::Logger->debug('Failed last-ticket date check');
                    next;
                }

                $due_date->add( days => $span );
            }
            elsif ( $content->{'repeat-details-daily'} eq 'weekday' ) {
                unless ( $checkday->day_of_week >= 1
                    && $checkday->day_of_week <= 5 )
                {
                    $RT::Logger->debug('Failed weekday check');
                    next;
                }

                if ( $checkday->day_of_week == 5 ) {
                    $due_date->add( days => 3 );
                }
                else {
                    $due_date->add( days => 1 );
                }
            }
            elsif ( $content->{'repeat-details-daily'} eq 'complete' ) {
                unless (
                    $last_ticket->QueueObj->Lifecycle->IsInactive(
                        $last_ticket->Status
                    )
                  )
                {
                    $RT::Logger->debug('Failed complete status check');
                    last;
                }

                my $resolved = $last_ticket->ResolvedObj;
                my $date     = $checkday->clone;
                $date->subtract(
                    days => $content->{'repeat-details-daily-complete'} || 1 );

                if ( $resolved->Date( Timezone => 'user' ) gt $date->ymd ) {
                    $RT::Logger->debug('Failed complete date check');
                    next;
                }
            }

        }
        elsif ( $content->{'repeat-type'} eq 'weekly' ) {
            if ( $content->{'repeat-details-weekly'} eq 'week' ) {
                my $span = $content->{'repeat-details-weekly-week'} || 1;
                my $date = $checkday->clone;

                unless ( CheckLastTicket( $date, $last_ticket, 'week', $span ) ) {
                    $RT::Logger->debug('Failed last-ticket date check');
                    next;
                }

                my $weeks = $content->{'repeat-details-weekly-weeks'};

                unless ( defined $weeks ) {
                    $RT::Logger->debug('Failed weeks defined check');
                    next;
                }

                $weeks = [$weeks] unless ref $weeks;
                unless ( grep { $_ == $checkday->day_of_week % 7 } @$weeks ) {
                    $RT::Logger->debug('Failed weeks check');
                    next;
                }

                @$weeks = sort @$weeks;
                $due_date->subtract( days => $due_date->day_of_week % 7 );

                my ($after) = after { $_ == $date->day_of_week % 7 } @$weeks;
                if ($after) {
                    $due_date->add( days => $after );
                }
                else {
                    $due_date->add( weeks => $span );
                    $due_date->add( days  => $weeks->[0] );
                }
            }
            elsif ( $content->{'repeat-details-weekly'} eq 'complete' ) {
                unless (
                    $last_ticket->QueueObj->Lifecycle->IsInactive(
                        $last_ticket->Status
                    )
                  )
                {
                    $RT::Logger->debug('Failed complete status check');
                    last;
                }
                my $resolved = $last_ticket->ResolvedObj;
                my $date     = $checkday->clone;
                $date->subtract(
                    weeks => $content->{'repeat-details-weekly-complete'}
                      || 1 );
                if ( $resolved->Date( Timezone => 'user' ) gt $date->ymd ) {
                    $RT::Logger->debug('Failed complete date check');
                    next;
                }
            }
        }
        elsif ( $content->{'repeat-type'} eq 'monthly' ) {
            if ( $content->{'repeat-details-monthly'} eq 'day' ) {
                my $day = $content->{'repeat-details-monthly-day-day'} || 1;
                unless ( $day == $checkday->day_of_month ) {
                    $RT::Logger->debug('Failed day of month check');
                    next;
                }

                my $span = $content->{'repeat-details-monthly-day-month'} || 1;
                my $date = $checkday->clone;
                unless ( CheckLastTicket( $date, $last_ticket, 'month', $span ) ) {
                    $RT::Logger->debug('Failed last-ticket date check');
                    next;
                }

                $due_date->add( months => $span );
            }
            elsif ( $content->{'repeat-details-monthly'} eq 'week' ) {
                my $day = $content->{'repeat-details-monthly-week-week'} || 0;
                unless ( $day == $checkday->day_of_week % 7 ) {
                    $RT::Logger->debug('Failed day of week check');
                    next;
                }

                my $number = $content->{'repeat-details-monthly-week-number'}
                  || 1;

                unless ( CheckWeekNumber( $checkday, $number ) ) {
                    $RT::Logger->debug('Failed week number check');
                    next;
                }

                my $span = $content->{'repeat-details-monthly-week-month'} || 1;
                my $date = $checkday->clone;
                unless ( CheckLastTicket( $date, $last_ticket, 'month', $span ) ) {
                    $RT::Logger->debug('Failed last-ticket date check');
                    next;
                }

                $due_date->add( months => $span );
                $due_date->truncate( to => 'month' );
                $due_date->add( weeks => $number - 1 );
                if ( $day > $due_date->day_of_week % 7 ) {
                    $due_date->add( days => $day - $due_date->day_of_week % 7 );
                }
                elsif ( $day < $due_date->day_of_week % 7 ) {
                    $due_date->add(
                        days => 7 + $day - $due_date->day_of_week % 7 );
                }
            }
            elsif ( $content->{'repeat-details-monthly'} eq 'complete' ) {
                unless (
                    $last_ticket->QueueObj->Lifecycle->IsInactive(
                        $last_ticket->Status
                    )
                  )
                {
                    $RT::Logger->debug('Failed complete status check');
                    last;
                }
                my $resolved = $last_ticket->ResolvedObj;
                my $date     = $checkday->clone;
                $date->subtract(
                    months => $content->{'repeat-details-monthly-complete'}
                      || 1 );
                if ( $resolved->Date( Timezone => 'user' ) gt $date->ymd ) {
                    $RT::Logger->debug('Failed complete date check');
                    next;
                }
            }
        }
        elsif ( $content->{'repeat-type'} eq 'yearly' ) {
            if ( $content->{'repeat-details-yearly'} eq 'day' ) {
                my $day = $content->{'repeat-details-yearly-day-day'} || 1;
                unless ( $day == $checkday->day_of_month ) {
                    $RT::Logger->debug('Failed day of month check');
                    next;
                }

                my $month = $content->{'repeat-details-yearly-day-month'} || 1;
                unless ( $month == $checkday->month ) {
                    $RT::Logger->debug('Failed month check');
                    next;
                }
                $due_date->add( years => 1 );
            }
            elsif ( $content->{'repeat-details-yearly'} eq 'week' ) {
                my $day = $content->{'repeat-details-yearly-week-week'} || 0;
                unless ( $day == $checkday->day_of_week % 7 ) {
                    $RT::Logger->debug('Failed day of week check');
                    next;
                }

                my $month = $content->{'repeat-details-yearly-week-month'} || 1;
                unless ( $month == $checkday->month ) {
                    $RT::Logger->debug('Failed month check');
                    next;
                }

                my $number = $content->{'repeat-details-yearly-week-number'}
                  || 1;
                unless ( CheckWeekNumber( $checkday, $number ) ) {
                    $RT::Logger->debug('Failed week number check');
                    next;
                }

                $due_date->add( years => 1 );
                $due_date->truncate( to => 'month' );
                $due_date->add( weeks => $number - 1 );
                if ( $day > $due_date->day_of_week % 7 ) {
                    $due_date->add( days => $day - $due_date->day_of_week % 7 );
                }
                elsif ( $day < $due_date->day_of_week % 7 ) {
                    $due_date->add(
                        days => 7 + $day - $due_date->day_of_week % 7 );
                }
            }
            elsif ( $content->{'repeat-details-yearly'} eq 'complete' ) {
                unless (
                    $last_ticket->QueueObj->Lifecycle->IsInactive(
                        $last_ticket->Status
                    )
                  )
                {
                    $RT::Logger->debug('Failed complete status check');
                    last;
                }
                my $resolved = $last_ticket->ResolvedObj;
                my $date     = $checkday->clone;
                $date->subtract(
                    years => $content->{'repeat-details-yearly-complete'}
                      || 1 );
                if ( $resolved->Date( Timezone => 'user' ) gt $date->ymd ) {
                    $RT::Logger->debug('Failed complete date check');
                    next;
                }
            }
        }

        # use RT::Date to work around the timezone issue
        my $starts = RT::Date->new( RT->SystemUser );
        $starts->Set( Format => 'unknown', Value => $checkday->ymd );

        my $due = RT::Date->new( RT->SystemUser );
        $due->Set( Format => 'unknown', Value => $due_date->ymd );

        my ( $id, $txn, $msg ) = _RepeatTicket(
            $repeat_ticket,
            Starts => $starts->ISO,
            $due_date eq $checkday
            ? ()
            : ( Due => $due->ISO ),
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

sub _RepeatTicket {
    my $repeat_ticket = shift;
    return unless $repeat_ticket;

    my %args  = @_;
    my $repeat = {
        Queue           => $repeat_ticket->Queue,
        Requestor       => join( ',', $repeat_ticket->RequestorAddresses ),
        Cc              => join( ',', $repeat_ticket->CcAddresses ),
        AdminCc         => join( ',', $repeat_ticket->AdminCcAddresses ),
        InitialPriority => $repeat_ticket->Priority,
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
    my $txn = $txns->First;
    my $atts = RT::Attachments->new(RT->SystemUser);
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
    my $attr     = shift;
    my $content = $attr->Content;

    my $co_number = RT->Config->Get('RepeatTicketCoexistentNumber') || 1;
    my $tickets = $content->{tickets} || [];

    my $last_ticket = RT::Ticket->new( RT->SystemUser );
    $last_ticket->Load( $content->{'last-ticket'} );

    my $date =
      $last_ticket->DueObj->Unix
      ? DateTime->from_epoch(
        epoch     => $last_ticket->DueObj->Unix - 3600 * 24,
        time_zone => RT->Config->Get('Timezone')
      )
      : DateTime->today( time_zone => RT->Config->Get('Timezone') );

    @$tickets = grep {
        my $t = RT::Ticket->new( RT->SystemUser );
        $t->Load($_);
        !$t->QueueObj->Lifecycle->IsInactive( $t->Status );
    } @$tickets;

    $content->{tickets} = $tickets;
    $attr->SetContent( $content );

    my @ids;
    if ( $co_number > @$tickets ) {
        my $total = $co_number - @$tickets;
        my @dates;
        if ( $content->{'repeat-type'} eq 'daily' ) {
            if ( $content->{'repeat-details-daily'} eq 'day' ) {
                my $span = $content->{'repeat-details-daily-day'} || 1;
                for ( 1 .. $total ) {
                    $date->add( days => $span );
                    push @dates, $date->clone;
                }
            }
            elsif ( $content->{'repeat-details-daily'} eq 'weekday' ) {
                while ( @dates < $total ) {
                    $date->add( days => 1 );
                    push @dates, $date->clone
                      if $date->day_of_week >= 1 && $date->day_of_week <= 5;
                }
            }
        }
        elsif ( $content->{'repeat-type'} eq 'weekly' ) {
            if ( $content->{'repeat-details-weekly'} eq 'week' ) {
                my $span = $content->{'repeat-details-weekly-week'} || 1;
                my $weeks = $content->{'repeat-details-weekly-weeks'};
                if (defined $weeks ) {
                    $weeks = [$weeks] unless ref $weeks;

                    if ( grep { $_ >= 0 && $_ <= 6 } @$weeks ) {
                        $date->add( weeks => $span );
                        $date->subtract( days => $date->day_of_week % 7 );

                        while ( @dates < $total ) {
                            for my $day ( sort @$weeks ) {
                                push @dates, $date->clone->add( days => $day );
                                last if @dates == $total;
                            }

                            $date->add( weeks => $span );
                        }
                    }
                }
            }
        }
        elsif ( $content->{'repeat-type'} eq 'monthly' ) {
            if ( $content->{'repeat-details-monthly'} eq 'day' ) {
                my $span = $content->{'repeat-details-monthly-day-month'} || 1;
                $date->set( day => $content->{'repeat-details-monthly-day-day'}
                      || 1 );

                for ( 1 .. $total ) {
                    $date->add( months => $span );
                    push @dates, $date->clone;
                }
            }
            elsif ( $content->{'repeat-details-monthly'} eq 'week' ) {
                my $span = $content->{'repeat-details-monthly-week-month'} || 1;
                my $number = $content->{'repeat-details-monthly-week-number'}
                  || 1;
                my $day = $content->{'repeat-details-monthly-week-week'} || 0;

                for ( 1 .. $total ) {
                    $date->add( months => $span );
                    $date->truncate( to => 'month' );
                    $date->add( weeks => $number - 1 );

                    if ( $day > $date->day_of_week % 7 ) {
                        $date->add( days => $day - $date->day_of_week % 7 );
                    }
                    elsif ( $day < $date->day_of_week % 7 ) {
                        $date->add( days => 7 + $day - $date->day_of_week % 7 );
                    }
                    push @dates, $date->clone;
                }
            }
        }
        elsif ( $content->{'repeat-type'} eq 'yearly' ) {
            if ( $content->{'repeat-details-yearly'} eq 'day' ) {
                $date->set( day => $content->{'repeat-details-yearly-day-day'}
                      || 1 );
                $date->set(
                    month => $content->{'repeat-details-yearly-day-month'}
                      || 1 );
                for ( 1 .. $total ) {
                    $date->add( years => 1 );
                    push @dates, $date->clone;
                }
            }
            elsif ( $content->{'repeat-details-yearly'} eq 'week' ) {
                $date->set(
                    month => $content->{'repeat-details-yearly-week-month'}
                      || 1 );

                my $number = $content->{'repeat-details-yearly-week-number'}
                  || 1;
                my $day = $content->{'repeat-details-yearly-week-week'} || 0;

                for ( 1 .. $total ) {
                    $date->add( years => 1 );
                    $date->truncate( to => 'month' );
                    $date->add( weeks => $number - 1 );
                    if ( $day > $date->day_of_week % 7 ) {
                        $date->add( days => $day - $date->day_of_week % 7  );
                    }
                    elsif ( $day < $date->day_of_week % 7  ) {
                        $date->add( days => 7 + $day - $date->day_of_week % 7  );
                    }
                    push @dates, $date->clone;
                }
            }
        }

        for my $date (@dates) {
            push @ids, Repeat( $attr, @dates );
        }
    }
    return @ids;
}

sub CheckLastTicket {
    my $date = shift;
    my $last_ticket = shift;
    my $type = shift;
    my $span = shift || 1;

    if ( $last_ticket->DueObj->Unix ) {
        my $due = $last_ticket->DueObj;
        if ( $date->ymd ge $due->Date( Timezone => 'user' ) ) {
            return 1;
        }
        else {
            return 0;
        }
    }

    my $created = DateTime->from_epoch(
        epoch     => $last_ticket->CreatedObj->Unix,
        time_zone => RT->Config->Get('Timezone'),
    );
    $created->truncate( to => 'day' );

    my $check = $date->clone();

    if ( $type eq 'day' ) {
        $check->subtract( days => $span );
        if ( $check->ymd ge $created->ymd ) {
            return 1;
        }
        else {
            return 0;
        }
    }
    elsif ( $type eq 'week' ) {
        my $created_week_start =
          $created->clone->subtract( days => $created->day_of_week % 7 );
        my $check_week_start =
          $check->clone->subtract( days => $check->day_of_week % 7 );

        return 0 unless $check_week_start > $created_week_start;

        return 1 if $span == 1;

        if ( ( $check_week_start->epoch - $created_week_start->epoch )
            % ( $span * 24 * 3600 * 7 ) )
        {
            return 0;
        }
        else {
            return 1;
        }
    }
    elsif ( $type eq 'month' ) {
        my $created_month_start = $created->clone->truncate( to => 'month' );
        my $check_month_start = $check->clone->truncate( to => 'month' );

        return 0 unless $check_month_start > $created_month_start;
        return 1 if $span == 1;

        if (
            (
                $check->year * 12 +
                $check->month -
                $created->year * 12 -
                $created->month
            ) % $span
          )
        {
            return 0;
        }
        else {
            return 1;
        }
    }

}

sub CheckWeekNumber {
    my $date = shift;
    my $number = shift || 1;
    if ( $number == 5 ) {    # last one, not just 5th
        my $next_month =
          $date->clone->truncate( to => 'month' )->add( months => 1 );
        if ( $next_month->epoch - $date->epoch <= 24 * 3600 * 7 ) {
            return 1;
        }
        else {
            return 0;
        }
    }
    else {
        if ( $number == int( ( $date->day_of_month - 1 ) / 7 ) + 1 ) {
            return 1;
        }
        else {
            return 0;
        }
    }
}

1;
__END__

=head1 NAME

RT::Extension::RepeatTicket - The great new RT::Extension::RepeatTicket!

=head1 VERSION

Version 0.01

=head1 INSTALLATION

To install this module, run the following commands:

    perl Makefile.PL
    make
    make install

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


