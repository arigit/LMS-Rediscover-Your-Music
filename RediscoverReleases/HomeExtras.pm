package Plugins::RediscoverReleases::HomeExtras;

# The Material skin home row. Material asks for the row's items with "rediscoverhome items <index> <quantity>",
# which the OPML feed below answers; tapping an album opens its tracks (LMS's own album track list), and its play
# buttons play the album. The feed is the whole list, so the row and its "more" view are the same items.

use strict;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Strings qw(cstring);

use Plugins::RediscoverReleases::List;

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

	my $items = [ map { _albumItem($client, $_) } @{ Plugins::RediscoverReleases::List::albumDetails() } ];
	$items = [{ name => cstring($client, 'PLUGIN_REDISCOVER_RELEASES_EMPTY'), type => 'text' }] unless @$items;

	$cb->({ items => $items });
}

sub _albumItem {
	my ($client, $album) = @_;

	my $artist = $album->{name} || '';
	my $title  = $album->{title} || '';

	return {
		name     => $title,   # also the favourite's name, like LMS's own album favourites
		line1    => $title,
		line2    => $artist . ($album->{year} ? ' (' . $album->{year} . ')' : ''),
		image    => $album->{artwork} ? 'music/' . $album->{artwork} . '/cover' : 'html/images/cover.png',
		type     => 'playlist',
		url      => \&Slim::Menu::BrowseLibrary::_tracks,
		playlist => \&Slim::Menu::BrowseLibrary::_tracks,
		# library_id -1: the list is server wide, so show and play the whole album whatever the player's library
		passthrough   => [{ searchTags => ['album_id:' . $album->{id}], library_id => -1 }],
		favorites_url => $album->{extid} || sprintf('db:album.title=%s&contributor.name=%s', uri_escape_utf8($title), uri_escape_utf8($artist)),
	};
}

1;
