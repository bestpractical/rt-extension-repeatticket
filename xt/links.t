use strict;
use warnings;

use RT::Extension::RepeatTicket::Test tests => undef;

use_ok('RT::Extension::RepeatTicket');

diag "Create the tickets the recurring ticket will link to.";

my $create_ticket = sub {
    my $subject = shift;
    my $ticket  = RT::Ticket->new( RT->SystemUser );
    my ($id)    = $ticket->Create( Queue => 'General', Subject => $subject );
    ok( $id, "created $subject: $id" );
    return $id;
};

my @targets   = map { $create_ticket->($_) } 'first target',   'second target';
my @referrers = map { $create_ticket->($_) } 'first referrer', 'second referrer';

diag "Create a recurring ticket linked to more than one ticket per direction.";

my $ticket = RT::Test->create_ticket(
    Queue   => 'General',
    Subject => 'recurring ticket with links',
    Content => 'Testing that links are cloned',
);
my $ticket_id = $ticket->id;
ok( $ticket_id, "created recurring ticket: $ticket_id" );

for my $target (@targets) {
    my ( $ok, $msg ) = $ticket->AddLink( Type => 'RefersTo', Target => $target );
    ok( $ok, "added RefersTo $target: $msg" );
}

for my $referrer (@referrers) {
    my ( $ok, $msg ) = $ticket->AddLink( Type => 'RefersTo', Base => $referrer );
    ok( $ok, "added ReferredToBy $referrer: $msg" );
}

is( $ticket->RefersTo->Count,     2, 'recurring ticket refers to two tickets' );
is( $ticket->ReferredToBy->Count, 2, 'recurring ticket is referred to by two tickets' );

my ( $attr, $msg ) = RT::Extension::RepeatTicket::SetRepeatAttribute(
    $ticket,
    'tickets'                         => [ $ticket->id ],
    'last-ticket'                     => $ticket->id,
    'repeat-enabled'                  => 1,
    'repeat-type'                     => 'daily',
    'repeat-details-daily'            => 'day',
    'repeat-details-daily-day'        => 1,
    'repeat-coexistent-number'        => 2,
    'repeat-create-on-recurring-date' => 0,
);
ok( $attr, "set recurrence: $msg" );

diag "Run the recurrence and check the new ticket carries the same links.";

my $tomorrow = DateTime->today->add( days => 1 );
my @ids = RT::Extension::RepeatTicket::Run( $attr, $tomorrow );
ok( @ids, 'recurrence created ticket(s): ' . join ', ', @ids );

my $ticket2 = RT::Ticket->new( RT->SystemUser );
$ticket2->Load( $ids[0] );
is( $ticket2->Subject, 'recurring ticket with links', "recurrence ticket $ids[0] created" );

# Before the fix these were joined into a single space-separated string,
# which RT could not resolve into a link, so every link was dropped and
# RT::URI logged "Could not determine a URI scheme for <id> <id>".
my %refers_to = map { $_->TargetObj->id => 1 } @{ $ticket2->RefersTo->ItemsArrayRef };
is_deeply( \%refers_to, { map { $_ => 1 } @targets },
    'both RefersTo links were cloned' );

my %referred_by = map { $_->BaseObj->id => 1 } @{ $ticket2->ReferredToBy->ItemsArrayRef };
is_deeply( \%referred_by, { map { $_ => 1 } @referrers },
    'both ReferredToBy links were cloned' );

done_testing;
