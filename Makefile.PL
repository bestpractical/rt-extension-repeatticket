use inc::Module::Install;
RTx('RT-Extension-RepeatTicket');
all_from('lib/RT/Extension/RepeatTicket.pm');
requires('DateTime::Event::ICal');
&auto_install();
&WriteAll;
