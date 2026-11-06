package Plugins::RediscoverReleases::HomeExtras;

# The Material skin home row. Material asks for the row's items with "rediscoverhome items <index> <quantity>",
# which the OPML feed below answers (items from Items.pm). The feed is the whole list, so the row and its "more" view
# are the same items.

use strict;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

use Plugins::RediscoverReleases::Items;

use constant ICON => 'plugins/RediscoverReleases/html/images/icon_svg.png';

__PACKAGE__->initPlugin();

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed  => \&feed,
		tag   => 'rediscoverhome',
		extra => {
			title       => 'PLUGIN_REDISCOVER_RELEASES',
			icon        => ICON,
			needsPlayer => 1,   # the feed is an OPML CLI query, which LMS only runs for a player
		},
	);
}

sub feed {
	my ($client, $cb, $args) = @_;

	# The whole list: the row is server wide, whatever the player's library
	$cb->({ items => Plugins::RediscoverReleases::Items::albumItems($client) });
}

1;
