use inc::Module::Install;
RTx('RT-Extension-RepeatTicket');
all_from('lib/RT/Extension/RepeatTicket.pm');

&auto_install();
&WriteAll;
