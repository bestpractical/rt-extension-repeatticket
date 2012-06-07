use warnings;
use strict;

package RT::Extension::RepeatTicket;

our $VERSION = "0.01";

use RT::Interface::Web;
use DateTime;
use RT::Date;

my $old_create_ticket = \&HTML::Mason::Commands::CreateTicket;
{
    no warnings 'redefine';

    *HTML::Mason::Commands::CreateTicket = sub {
        my %args = @_;
        my ( $ticket, @actions ) = $old_create_ticket->(@_);
        SetRepeatAttribute( $ticket, %args ) if $ticket && $args{'repeat-enabled'};
        return ( $ticket, @actions );
    };
}

sub SetRepeatAttribute {
    my $ticket = shift;
    return 0 unless $ticket;
    my %args = @_;
    my %repeat_args = map { $_ => $args{$_} } grep { /^repeat/ } keys %args;

    my ( $old_attr ) = $ticket->Attributes->Named('RepeatTicketSettings');
    my %old;
    %old = %{$old_attr->Content} if $old_attr;

    my $content = { %old, %repeat_args };
    $ticket->SetAttribute(
        Name    => 'RepeatTicketSettings',
        Content => $content,
    );

    return ( 1, $ticket->loc('Recurrence updated') );    # loc
}

use RT::Ticket;
sub RepeatTicket {
    my $attr     = shift;
    my $checkday = shift;

    my $content = $attr->Content;
    return unless $content->{'repeat-enabled'};

    my $repeat_ticket = $attr->Object;

    if ( $content->{'repeat-start-date'} ) {
        my $date = RT::Date->new( RT->SystemUser );
        $date->Set(
            Format => 'unknown',
            Value  => $content->{'repeat-start-date'},
        );
        return unless $checkday->ymd ge $date->Date;
    }

    if ( $content->{'repeat-end'} && $content->{'repeat-end'} eq 'number' ) {
        return
          unless $content->{'repeat-end-number'} >
              $content->{'repeat-occurrences'};
    }

    if ( $content->{'repeat-end'} && $content->{'repeat-end'} eq 'date' ) {
        my $date = RT::Date->new( RT->SystemUser );
        $date->Set(
            Format => 'unknown',
            Value  => $content->{'repeat-end-date'},
        );
        return unless $checkday->ymd lt $date->Date;
    }

    my $last_ticket;
    if ( $content->{'last-ticket'} ) {
        $last_ticket = RT::Ticket->new( RT->SystemUser );
        $last_ticket->Load( $content->{'last-ticket'} );
    }

    $last_ticket ||= $repeat_ticket;

    my $due_date = $checkday->clone;

    if ( $content->{'repeat-type'} eq 'daily' ) {
        if ( $content->{'repeat-details-daily'} eq 'day' ) {
            my $span = $content->{'repeat-details-daily-day'} || 1;
            my $date = $checkday->clone;
            $date->subtract( days => $span );
            return unless CheckLastTicket( $date, $last_ticket );

            $due_date->add( days => $span );
        }
        elsif ( $content->{'repeat-details-daily'} eq 'weekday' ) {
            return
              unless $checkday->day_of_week >= 1 && $checkday->day_of_week <= 5;
            if ( $checkday->day_of_week == 5 ) {
                $due_date->add( days => 3 );
            }
            else {
                $due_date->add( days => 1 );
            }
        }
        elsif ( $content->{'repeat-details-daily'} eq 'complete' ) {
            return
              unless $last_ticket->QueueObj->Lifecycle->IsInactive(
                $last_ticket->Status );
            my $resolved = $last_ticket->ResolvedObj;
            my $date     = $checkday->clone;
            $date->subtract( days => $content->{'repeat-details-daily-complete'}
                  || 1 );
            return if $resolved->Date gt $date->ymd;
        }

    }
    elsif ( $content->{'repeat-type'} eq 'weekly' ) {
        if ( $content->{'repeat-details-weekly'} eq 'week' ) {
            my $span = $content->{'repeat-details-weekly-week'} || 1;
            my $date = $checkday->clone;

            # go to the end of the week
            $date->subtract(
                weeks => $span - 1,
                days  => $checkday->day_of_week
            );
            return unless CheckLastTicket( $date, $last_ticket );

            my $weeks = $content->{'repeat-details-weekly-weeks'};
            return unless $weeks;

            $weeks = [$weeks] unless ref $weeks;
            return unless grep { $_ == $checkday->day_of_week } @$weeks;

            $due_date->add( weeks => $span );
            $due_date->subtract( days => $due_date->day_of_week );
            my ($first) = sort @$weeks;
            $due_date->add( days => $first ) if $first;
        }
        elsif ( $content->{'repeat-details-weekly'} eq 'complete' ) {
            return
              unless $last_ticket->QueueObj->Lifecycle->IsInactive(
                $last_ticket->Status );
            my $resolved = $last_ticket->ResolvedObj;
            my $date     = $checkday->clone;
            $date->subtract(
                weeks => $content->{'repeat-details-weekly-complete'} || 1 );
            return if $resolved->Date gt $date->ymd;
        }
    }
    elsif ( $content->{'repeat-type'} eq 'monthly' ) {
        if ( $content->{'repeat-details-monthly'} eq 'day' ) {
            my $day = $content->{'repeat-details-monthly-day-day'} || 1;
            return unless $day == $checkday->day_of_month;

            my $span = $content->{'repeat-details-monthly-day-month'} || 1;
            my $date = $checkday->clone;
            $date->subtract( months => $span );
            return unless CheckLastTicket( $date, $last_ticket );

            $due_date->add( months => $span );
        }
        elsif ( $content->{'repeat-details-monthly'} eq 'week' ) {
            my $day = $content->{'repeat-details-monthly-week-week'} || 0;
            return unless $day == $checkday->day_of_week;

            my $number = $content->{'repeat-details-monthly-week-number'} || 1;
            return
              unless $number == int( ( $checkday->day_of_month - 1 ) / 7 ) + 1;

            my $span = $content->{'repeat-details-monthly-week-month'} || 1;
            my $date = $checkday->clone;
            $date->subtract( months => $span );
            return unless CheckLastTicket( $date, $last_ticket );

            $due_date->add( months => $span );
            $due_date->subtract( days => $due_date->day_of_month - 1 );
            $due_date->add( weeks => $number - 1 );
            if ( $day > $due_date->day_of_week ) {
                $due_date->add( days => $day - $due_date->day_of_week );
            }
            elsif ( $day < $due_date->day_of_week ) {
                $due_date->add( days => 7 + $day - $due_date->day_of_week );
            }
        }
        elsif ( $content->{'repeat-details-monthly'} eq 'complete' ) {
            return
              unless $last_ticket->QueueObj->Lifecycle->IsInactive(
                $last_ticket->Status );
            my $resolved = $last_ticket->ResolvedObj;
            my $date     = $checkday->clone;
            $date->subtract(
                months => $content->{'repeat-details-monthly-complete'} || 1 );
            return if $resolved->Date gt $date->ymd;
        }
    }
    elsif ( $content->{'repeat-type'} eq 'yearly' ) {
        if ( $content->{'repeat-details-yearly'} eq 'day' ) {
            my $day = $content->{'repeat-details-yearly-day-day'} || 1;
            return unless $day == $checkday->day_of_month;

            my $month = $content->{'repeat-details-yearly-day-month'} || 1;
            return unless $month == $checkday->month;
            $due_date->add( years => 1 );
        }
        elsif ( $content->{'repeat-details-yearly'} eq 'week' ) {
            my $day = $content->{'repeat-details-yearly-week-week'} || 0;
            return unless $day == $checkday->day_of_week;

            my $month = $content->{'repeat-details-yearly-week-month'} || 1;
            return unless $month == $checkday->month;

            my $number = $content->{'repeat-details-yearly-week-number'} || 1;
            return
              unless $number == int( ( $checkday->day_of_month - 1 ) / 7 ) + 1;

            $due_date->add( year => 1 );
            $due_date->subtract( days => $due_date->day_of_month - 1 );
            $due_date->add( weeks => $number - 1 );
            if ( $day > $due_date->day_of_week ) {
                $due_date->add( days => $day - $due_date->day_of_week );
            }
            elsif ( $day < $due_date->day_of_week ) {
                $due_date->add( days => 7 + $day - $due_date->day_of_week );
            }
        }
        elsif ( $content->{'repeat-details-yearly'} eq 'complete' ) {
            return
              unless $last_ticket->QueueObj->Lifecycle->IsInactive(
                $last_ticket->Status );
            my $resolved = $last_ticket->ResolvedObj;
            my $date     = $checkday->clone;
            $date->subtract(
                years => $content->{'repeat-details-yearly-complete'} || 1 );
            return
              if $resolved->Date gt $date->ymd;
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
        $RT::Logger->info( "Repeated Ticket $id for " . $repeat_ticket->id );
        $content->{'repeat-occurrences'}++;
        $content->{'last-ticket'} = $id;
        $attr->SetContent($content);
        return ( $id, $txn, $msg );
    }
    else {
        $RT::Logger->error(
            "Failed to repeat ticket for " . $repeat_ticket->id . ": $msg" );
        return;
    }
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

    my $atts = RT::Attachments->new($RT::SystemUser);
    $atts->OrderBy( FIELD => 'id', ORDER => 'ASC' );
    $atts->Limit( FIELD => 'TransactionId', VALUE => $txn->id );
    $atts->Limit( FIELD => 'Parent',        VALUE => 0 );
    $atts->RowsPerPage(1);

    my $top = $atts->First;
    if ($top) {
        $args{MIMEObj} = $top->ContentAsMIME( Children => 1 );
    }

    my $ticket = RT::Ticket->new( RT->SystemUser );
    return $ticket->Create(%args);
}

sub CheckLastTicket {
    my $date = shift;
    my $last_ticket = shift;
    if ( $last_ticket->DueObj->Unix ) {
        my $due = $last_ticket->DueObj;
        $due->AddDays(-1);
        if ( $date->ymd ge $due->Date( Timezone => 'user' ) ) {
            return 1;
        }
        else {
            return 0;
        }
    }

    if ( $date->ymd ge $last_ticket->CreatedObj->Date( Timezone => 'user' ) ) {
        return 1;
    }
    else {
        return 0;
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

=head1 AUTHOR

sunnavy, <sunnavy at bestpractical.com>


=head1 LICENSE AND COPYRIGHT

Copyright 2012 sunnavy.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


