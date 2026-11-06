package Plugins::RediscoverReleases::Browse;

# The list as an entry of LMS's "My Music" browse menu. Material shows these entries as browse modes (Settings >
# Browse modes); the other skins and apps show them under My Music. With a Library View selected on the player, only
# the listed albums with a track in it are shown.

use strict;

use Slim::Menu::BrowseLibrary;

use Plugins::RediscoverReleases::Items;

use constant ICON => 'plugins/RediscoverReleases/html/images/icon_svg.png';

sub init {
	Slim::Menu::BrowseLibrary->registerNode({
		type         => 'link',
		id           => 'rediscoverReleases',
		name         => 'PLUGIN_REDISCOVER_RELEASES',
		homeMenuText => 'PLUGIN_REDISCOVER_RELEASES',
		params       => { mode => 'rediscoverReleases' },
		feed         => \&feed,
		icon         => ICON,
		jiveIcon     => ICON,
		weight       => 55,   # after New Music (50)
		cache        => 0,    # the list changes
	});
}

sub feed {
	my ($client, $cb, $args, $pt) = @_;
	my $libraryId = ($args && $args->{params} && $args->{params}->{library_id})
		|| Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
	$cb->({ items => Plugins::RediscoverReleases::Items::albumItems($client, $libraryId) });
}

1;
