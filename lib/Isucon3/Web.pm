package Isucon3::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use DBIx::Sunny;
use JSON qw/ decode_json /;
use Digest::SHA qw/ sha256_hex /;
use DBIx::Sunny;
use File::Temp qw/ tempfile /;
use IO::Handle;
use Encode;
use Time::Piece;
use Text::Markdown::Discount 'markdown';
use Cache::Memcached::Fast;
use Data::Dump qw/dump/;

my %uri_for;

my $_config;
sub load_config {
    my $self = shift;
    $_config ||= do {
        my $env = $ENV{ISUCON_ENV} || 'local';
        open(my $fh, '<', $self->root_dir . "/../config/${env}.json") or die $!;
        my $json = do { local $/; <$fh> };
        close($fh);
        decode_json($json);
    };
}

my $_dbh;
sub dbh {
    my ($self) = @_;
    $_dbh ||= do {
        my $dbconf = $self->load_config->{database};
        DBIx::Sunny->connect(
            "dbi:mysql:database=${$dbconf}{dbname};host=${$dbconf}{host};port=${$dbconf}{port}", $dbconf->{username}, $dbconf->{password}, {
                RaiseError => 1,
                PrintError => 0,
                AutoInactiveDestroy => 1,
                mysql_enable_utf8   => 1,
                mysql_auto_reconnect => 1,
            },
        );
    };
}

my $_cache;
sub cache {
    my ($self) = @_;
    $_cache ||= do {
        Cache::Memcached::Fast->new({ servers => ['localhost:11212'] });
    };
}

filter 'session' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        my $sid = $c->req->env->{"psgix.session.options"}->{id};
        $c->stash->{session_id} = $sid;
        $c->stash->{session}    = $c->req->env->{"psgix.session"};
        $app->($self, $c);
    };
};

my %users;
sub _user {
    my ($self, $user_id) = @_;
    return unless $user_id;
    my $user = $users{$user_id};
    unless ($user) {
        $user = $self->dbh->select_row(
            'SELECT * FROM users WHERE id=?',
            $user_id,
        );
        $users{$user_id} = $user;
    }
    return $user;
}

sub _total {
    my $self = shift;
    my $total = $self->cache->get('total_memos');
    unless($total) {
        $total = $self->dbh->select_one(
            'SELECT count(*) FROM memos WHERE is_private=0'
        );
        $self->cache->set(total_memos => $total);
    }
    return $total;
}

filter 'get_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;

        my $user_id = $c->req->env->{"psgix.session"}->{user_id};
        $c->stash->{user} = $self->_user($user_id);
        $c->res->header('Cache-Control', 'private') if $c->stash->{user};
        $app->($self, $c);
    }
};

filter 'require_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        unless ( $c->stash->{user} ) {
            return $c->redirect('/');
        }
        $app->($self, $c);
    };
};

filter 'anti_csrf' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        my $sid   = $c->req->param('sid');
        my $token = $c->req->env->{"psgix.session"}->{token};
        if ( $sid ne $token ) {
            return $c->halt(400);
        }
        $app->($self, $c);
    };
};

get '/' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;

    my $memos = $self->cache->get('index');
    unless ($memos) {
        $memos = $self->dbh->select_all(
            'SELECT * FROM memos WHERE is_private=0 ORDER BY created_at DESC, id DESC LIMIT 100',
        );
        for my $memo (@$memos) {
            $memo->{username} = $self->_user($memo->{user})->{username};
        }
        $self->cache->set('index' => $memos);
    }
    $c->render('index.tx', {
        memos => $memos,
        page  => 0,
        total => $self->_total,
        uri_for => sub { $uri_for{$_[0]} //= $c->req->uri_for($_[0]) },
    });
};

get '/recent/:page' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    my $page  = int $c->args->{page};
    my $memos = $self->cache->get("recent_$page");
    unless ($memos) {
        $memos = $self->dbh->select_all(
            sprintf("SELECT * FROM memos WHERE is_private=0 ORDER BY created_at DESC, id DESC LIMIT 100 OFFSET %d", $page * 100)
        );
        if ( @$memos == 0 ) {
            return $c->halt(404);
        }
        for my $memo (@$memos) {
            $memo->{username} = $self->_user($memo->{user})->{username};
        }
        $self->cache->set("recent_$page" => $memos);
    }
    $c->render('index.tx', {
        memos => $memos,
        page  => $page,
        total => $self->_total,
        uri_for => sub { $uri_for{$_[0]} //= $c->req->uri_for($_[0]) },
    });
};

get '/signin' => sub {
    my ($self, $c) = @_;
    $c->render('signin.tx', {
        uri_for => sub { $uri_for{$_[0]} //= $c->req->uri_for($_[0]) },
    });
};

post '/signout' => [qw(session get_user require_user anti_csrf)] => sub {
    my ($self, $c) = @_;
    $c->req->env->{"psgix.session.options"}->{change_id} = 1;
    delete $c->req->env->{"psgix.session"}->{user_id};
    $c->redirect('/');
};

post '/signup' => [qw(session anti_csrf)] => sub {
    my ($self, $c) = @_;

    my $username = $c->req->param("username");
    my $password = $c->req->param("password");
    my $user = $self->dbh->select_row(
        'SELECT id, username, password, salt FROM users WHERE username=?',
        $username,
    );
    if ($user) {
        $c->halt(400);
    }
    else {
        my $salt = substr( sha256_hex( time() . $username ), 0, 8 );
        my $password_hash = sha256_hex( $salt, $password );
        $self->dbh->query(
            'INSERT INTO users (username, password, salt) VALUES (?, ?, ?)',
            $username, $password_hash, $salt,
        );
        my $user_id = $self->dbh->last_insert_id;
        $self->cache->set("user_$user_id" => { username => $username, id => $user_id });
        $c->req->env->{"psgix.session"}->{user_id} = $user_id;
        $c->redirect('/mypage');
    }
};

post '/signin' => [qw(session)] => sub {
    my ($self, $c) = @_;

    my $username = $c->req->param("username");
    my $password = $c->req->param("password");
    my $user = $self->dbh->select_row(
        'SELECT id, username, password, salt FROM users WHERE username=?',
        $username,
    );
    if ( $user && $user->{password} eq sha256_hex($user->{salt} . $password) ) {
        $c->req->env->{"psgix.session.options"}->{change_id} = 1;
        my $session = $c->req->env->{"psgix.session"};
        $session->{user_id} = $user->{id};
        $session->{token}   = sha256_hex(rand());
        #$self->dbh->query(
        #    'UPDATE users SET last_access=now() WHERE id=?',
        #    $user->{id},
        #);
        return $c->redirect('/mypage');
    }
    else {
        $c->render('signin.tx', {
            uri_for => sub { $uri_for{$_[0]} //= $c->req->uri_for($_[0]) },
        });
    }
};

get '/mypage' => [qw(session get_user require_user)] => sub {
    my ($self, $c) = @_;

    my $memos = $self->cache->get('mypage_' . $c->stash->{user}->{id});
    unless ($memos) {
        $memos = $self->dbh->select_all(
            'SELECT id, content, is_private, created_at, updated_at FROM memos WHERE user=? ORDER BY created_at DESC',
            $c->stash->{user}->{id},
        );
        $self->cache->set('mypage_' . $c->stash->{user}->{id} => $memos);
    }
    $c->render('mypage.tx', {
        memos => $memos,
        uri_for => sub { $uri_for{$_[0]} //= $c->req->uri_for($_[0]) },
    });
};

post '/memo' => [qw(session get_user require_user anti_csrf)] => sub {
    my ($self, $c) = @_;

    $self->dbh->query(
        'INSERT INTO memos (user, content, is_private, created_at) VALUES (?, ?, ?, now())',
        $c->stash->{user}->{id},
        scalar $c->req->param('content'),
        scalar($c->req->param('is_private')) ? 1 : 0,
    );
    my $memo_id = $self->dbh->last_insert_id;
    my $memo = { id => $memo_id, user => $c->stash->{user}->{id}, content => scalar $c->req->param('content'), is_private => scalar($c->req->param('is_private')) ? 1 : 0, created_at => ''};
    unless (scalar($c->req->param('is_private'))) {
        $self->cache->incr('total_memos');
        if (my $memos = $self->cache->get('index')) {
            unshift @$memos, $memo;
            pop @$memos if scalar(@$memos) > 100;
            $self->cache->set('index' => $memos);
        }
    }
    $self->cache->set('memo_' . $memo_id => $memo);
    $c->redirect('/memo/' . $memo_id);
};

get '/memo/:id' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;

    my $user = $c->stash->{user};
    my $memo = $self->cache->get('memo_' . $c->args->{id});
    unless ($memo) {
        $memo = $self->dbh->select_row(
            'SELECT id, user, content, is_private, created_at, updated_at FROM memos WHERE id=?',
            $c->args->{id},
        );
        $self->cache->set('memo_' . $c->args->{id} => $memo) if $memo;
    }
    unless ($memo) {
        $c->halt(404);
    }
    if ($memo->{is_private}) {
        if ( !$user || $user->{id} != $memo->{user} ) {
            $c->halt(404);
        }
    }
    $memo->{content_html} = markdown($memo->{content});
    $memo->{username} = $self->_user($memo->{user});

    my $cond;
    if ($user && $user->{id} == $memo->{user}) {
        $cond = "";
    }
    else {
        $cond = "AND is_private=0";
    }

    my $memos = $self->dbh->select_all(
        "SELECT * FROM memos WHERE user=? $cond ORDER BY created_at",
        $memo->{user},
    );
    my ($newer, $older);
    for my $i ( 0 .. scalar @$memos - 1 ) {
        if ( $memos->[$i]->{id} eq $memo->{id} ) {
            $older = $memos->[ $i - 1 ] if $i > 0;
            $newer = $memos->[ $i + 1 ] if $i < @$memos;
        }
    }

    $c->render('memo.tx', {
        memo  => $memo,
        older => $older,
        newer => $newer,
        uri_for => sub { $uri_for{$_[0]} //= $c->req->uri_for($_[0]) },
    });
};

1;
