package Plugins::RediscoverReleases::Items;

# The list's albums as XMLBrowser (OPML) items, for the Material home row (HomeExtras.pm) and the browse menu
# (Browse.pm). Album items carry LMS's album actions, so tapping one opens the client's album view, and its play
# buttons play the album.

use strict;

use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Strings qw(cstring);

use Plugins::RediscoverReleases::List;

# The list (with a Library View ID only its albums with a track in it) as items, or a text item if it is empty.
sub albumItems {
	my ($client, $libraryId) = @_;
	my $items = [ map { albumItem($client, $_) } @{ Plugins::RediscoverReleases::List::albumDetails($libraryId) } ];
	$items = [{ name => cstring($client, 'PLUGIN_REDISCOVER_RELEASES_EMPTY'), type => 'text' }] unless @$items;
	return $items;
}

sub albumItem {
	my ($client, $album) = @_;

	my $artist = $album->{name} || '';
	my $title  = $album->{title} || '';

	# The actions LMS gives its own album items. Material turns 'items' (browselibrary, mode tracks) into its own
	# album view; without them a tap opened this feed's plain track list (1.0.1).
	my %album = (album_id => $album->{id}, library_id => -1);
	# At most 4 of LMS's 5 actions (insert is left to the feed's own action): with all 5, or allAvailableActionsDefined,
	# LMS leaves out the item's item_id, which Material builds the item's id from; without it the id has no ':' and
	# Material's album view failed (TypeError in browseHandleListResponse).
	my %actions = (
		info   => { command => ['albuminfo', 'items'], fixedParams => { %album } },
		items  => { command => ['browselibrary', 'items'], fixedParams => { mode => 'tracks', %album } },
		play   => { command => ['playlistcontrol'], fixedParams => { cmd => 'load', %album } },
		add    => { command => ['playlistcontrol'], fixedParams => { cmd => 'add', %album } },
	);
	$actions{playall} = $actions{play};
	$actions{addall}  = $actions{add};

	return {
		itemActions => \%actions,
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
