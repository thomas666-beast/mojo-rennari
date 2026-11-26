
use strict; use warnings; use Test::More; use JSON::PP;
use Mojo::IOLoop;
use Mojo::Rennari::Server;

# Timers are captured instead of run, so the tests can fire them by hand.
our (%T, $N);
{
    no warnings 'redefine';
    *Mojo::IOLoop::timer   = sub { my ($class, $delay, $cb) = @_; $T{ ++$N } = $cb; return $N };
    *Mojo::IOLoop::remove  = sub { delete $T{ $_[1] } };
    *Mojo::IOLoop::fire    = sub { my $cb = delete $T{ $_[1] } or return 0; $cb->(); 1 };
    *Mojo::IOLoop::pending = sub { scalar keys %T };
}
package FakeTx { sub new { bless {ev=>{}, sent=>[], closed=>undef}, shift }
  sub on { my ($s,$n,$cb)=@_; push @{$s->{ev}{$n}}, $cb; $cb } sub once { my ($s,$n,$cb)=@_; my $w; $w=sub { @{$s->{ev}{$n}} = grep { $_ ne $w } @{$s->{ev}{$n}}; $cb->(@_) }; push @{$s->{ev}{$n}}, $w }
  sub emit { my ($s,$n,@a)=@_; $_->($s,@a) for @{[@{$s->{ev}{$n}||[]}]} } sub send { push @{$_[0]{sent}}, $_[1]; 1 }
  sub finish { my $s=shift; $s->{closed}=[@_]; $s->emit('finish') } sub max_websocket_size { $_[0]{max}=$_[1] } }
package FakeHeaders { sub new { bless {%{$_[1]}}, $_[0] } sub header { $_[0]{lc $_[1]} } sub authorization { $_[0]{authorization} } sub origin { $_[0]{origin} } }
package FakeC { sub new { my ($c,%h)=@_; bless {tx=>FakeTx->new, h=>FakeHeaders->new({map { lc($_)=>$h{$_} } keys %h}), stash=>{}, upgraded=>0}, $c }
  sub tx { $_[0]{tx} } sub req { $_[0] } sub headers { $_[0]{h} } sub app { $_[0] } sub mode { 'development' }
  sub stash { my $s=shift; return $s->{stash}{$_[0]} if @_==1; $s->{stash}{$_[0]}=$_[1] } sub inactivity_timeout {}
  sub on { my ($s,$n,$cb)=@_; $s->{upgraded}=1; $s->{tx}->on($n => sub { shift; $cb->($s,@_) }) }
  sub render { my ($s,%a)=@_; $s->{rendered}=\%a; undef } sub send { push @{$_[0]{replayed}}, $_[1] } }
package main;
my $TOK = 'a' x 40; my $quiet = bless {}, 'Q'; { package Q; sub AUTOLOAD { our $AUTOLOAD; my $n=$AUTOLOAD; $n=~s/.*:://; return if $n eq 'DESTROY'; push @{$main::LOG}, "$n: $_[1]"; } }
our $LOG = [];
sub srv { Mojo::Rennari::Server->new(app_token=>$TOK, logger=>$quiet, serializer=>'json', @_) }
sub fr { JSON::PP->new->canonical->encode({e=>$_[0], d=>$_[1], %{$_[2]||{}}}) }
sub sent_events { [map { JSON::PP->new->decode($_->{binary})->{e} } @{$_[0]{tx}{sent}}] }

# Tests for the two-layer login (app token + optional auth_cb), run without a network.
# construction
ok(!eval { Mojo::Rennari::Server->new(logger=>$quiet); 1 }, 'new dies without app_token'); like($@, qr/app_token is required/);
ok(!eval { Mojo::Rennari::Server->new(app_token=>'short'); 1 }, 'short token refused');
ok(!eval { Mojo::Rennari::Server->new(app_token=>'CHANGE_ME'); 1 }, 'CHANGE_ME refused');
ok(eval { Mojo::Rennari::Server->new(mock=>1); 1 }, 'mock needs no token');

# header path
{ my $s=srv(); my $connected=0; $s->on_connect(sub { $connected++ });
  my $c=FakeC->new('X-Rennari-App-Token'=>$TOK); $s->websocket_route($c);
  ok(!$c->{tx}{closed}, 'valid header: open'); is($connected,1,'connect hook'); is($c->stash('rennari_identity') && ref $c->stash('rennari_identity'),'HASH','identity {}');
}
{ my $s=srv(); my $c=FakeC->new('X-Rennari-App-Token'=>('b' x 40)); $s->websocket_route($c);
  is_deeply($c->{tx}{closed}, [4001,'unauthorized'], 'wrong header: 4001'); ok($c->{upgraded}, 'upgrade forced before close'); }
{ my $s=srv(); my $c=FakeC->new('X-Rennari-App-Token'=>'short'); $s->websocket_route($c); is($c->{tx}{closed}[0],4001,'malformed header: 4001'); }
{ my $seen; my $s=srv(auth_cb=>sub { $seen=$_[1]; { id=>'u1', name=>'n' } });
  my $c=FakeC->new('X-Rennari-App-Token'=>$TOK, Authorization=>'Bearer user-secret'); $s->websocket_route($c);
  ok(!$c->{tx}{closed}, 'header + bearer open'); is($seen->{token}, 'user-secret', 'bearer to auth_cb'); is_deeply($seen->{auth}, {}, 'auth empty'); }

# browser path
{ my $s=srv(); my $c=FakeC->new(); $s->websocket_route($c);
  is(scalar @{$c->{tx}{sent}}, 0, 'nothing sent before auth'); ok(!$c->{tx}{closed}, 'waiting');
  is(Mojo::IOLoop->pending, 1, 'timer armed');
  $c->{tx}->emit(message => fr(auth=>{app_token=>$TOK}));
  ok(!$c->{tx}{closed}, 'auth frame accepted'); is(Mojo::IOLoop->pending, 0, 'timer removed');
  $c->{tx}->emit(message => fr(auth=>{app_token=>'x'})); ok(!$c->{tx}{closed}, 'later auth frame ignored'); }
{ my $seen; my $s=srv(auth_cb=>sub { $seen=$_[1]; { id=>'u1' } }); my $c=FakeC->new(); $s->websocket_route($c);
  $c->{tx}->emit(message => fr(auth=>{app_token=>$TOK, token=>'tok', extra=>7}));
  ok(!$c->{tx}{closed}, 'auth + token ok'); is($seen->{token},'tok','token'); is($seen->{auth}{extra},7,'extra'); ok(!exists $seen->{auth}{app_token}, 'app_token stripped'); }
{ my $s=srv(); my $c=FakeC->new(); $s->websocket_route($c); $c->{tx}->emit(message => fr(auth=>{app_token=>'c' x 40}));
  is($c->{tx}{closed}[0],4001,'wrong frame token: 4001'); }
{ my $s=srv(); my $c=FakeC->new(); $s->websocket_route($c); $c->{tx}->emit(message => fr(auth=>{}));
  is($c->{tx}{closed}[0],4001,'missing app_token: 4001'); }
{ my $s=srv(); $s->on(echo=>sub { {x=>1} }); my $c=FakeC->new(); $s->websocket_route($c); $c->{tx}->emit(message => fr(echo=>{}));
  is($c->{tx}{closed}[0],4001,'first frame not auth: 4001'); is(scalar @{$c->{tx}{sent}},0,'no reply'); }
{ my $s=srv(); my $c=FakeC->new(); $s->websocket_route($c); $c->{tx}->emit(message => 'not json');
  is($c->{tx}{closed}[0],4001,'undecodable first frame: 4001'); ok((grep /serializer mismatch/, @$LOG), 'log names serializer mismatch'); }
{ my $s=srv(); my $c=FakeC->new(); $s->websocket_route($c); my ($id)=keys %main::T; Mojo::IOLoop->fire($id);
  is_deeply($c->{tx}{closed}, [4001,'auth_timeout'], 'timeout: auth_timeout'); }
{ my $s=srv(); my $c=FakeC->new(); $s->websocket_route($c); $c->{tx}->emit('finish'); is(Mojo::IOLoop->pending,0,'timer cleaned on early close'); }

# auth_cb failure modes
for my $case ([die=>sub { die "db down\n" }], [undef=>sub { undef }], [scalar=>sub { 'yes' }]) {
  my $s=srv(auth_cb=>$case->[1]); my $c=FakeC->new('X-Rennari-App-Token'=>$TOK); $s->websocket_route($c); is($c->{tx}{closed}[0],4001,"auth_cb $case->[0]: 4001"); }
{ my $s=srv(recovery=>1, auth_cb=>sub { {name=>'noid'} }); my $c=FakeC->new('X-Rennari-App-Token'=>$TOK); $s->websocket_route($c); is($c->{tx}{closed}[0],4001,'recovery needs id with auth_cb'); }
{ my $s=srv(recovery=>1); my $c=FakeC->new('X-Rennari-App-Token'=>$TOK); $s->websocket_route($c); ok(!$c->{tx}{closed}, 'recovery without auth_cb ok'); is_deeply(sent_events($c), ['rennari_session'], 'session announced after auth'); }

# origin
{ my $s=srv(allowed_origins=>['http://localhost:5173']); my $c=FakeC->new(Origin=>'http://evil.example'); $s->websocket_route($c);
  is($c->{rendered}{status},403,'bad origin 403'); ok(!$c->{upgraded}, 'no upgrade'); 
  my $c2=FakeC->new(Origin=>'http://localhost:5173'); $s->websocket_route($c2); ok(!$c2->{rendered}, 'good origin passes'); 
  my $c3=FakeC->new('X-Rennari-App-Token'=>$TOK); $s->websocket_route($c3); ok(!$c3->{rendered}, 'no Origin header passes'); }

# events work after browser login, unknown event closes 4003
{ my $s=srv(); $s->on(echo=>sub { {m=>$_[1]{m}} }); my $c=FakeC->new(); $s->websocket_route($c);
  $c->{tx}->emit(message => fr(auth=>{app_token=>$TOK})); $c->{tx}->emit(message => fr(echo=>{m=>'hi'}));
  is_deeply(sent_events($c), ['reply'], 'echo replies after login'); $c->{tx}->emit(message => fr(nope=>{})); is($c->{tx}{closed}[0],4003,'unknown event 4003'); }

# resume needs the same identity
{ my $s=srv(recovery=>1, auth_cb=>sub { { id => ($_[1]{token} // 'x') } });
  my $a=FakeC->new('X-Rennari-App-Token'=>$TOK, Authorization=>'Bearer alice'); $s->websocket_route($a);
  my $sid = JSON::PP->new->decode($a->{tx}{sent}[0]{binary})->{d}{id}; $a->{tx}->emit('finish');
  my $b=FakeC->new('X-Rennari-App-Token'=>$TOK, Authorization=>'Bearer bob'); $s->websocket_route($b);
  $b->{tx}->emit(message => fr(rennari_resume=>{session_id=>$sid, offset=>0}));
  is((sent_events($b))->[-1], 'rennari_resume_failed', 'other identity cannot resume');
  my $a2=FakeC->new('X-Rennari-App-Token'=>$TOK, Authorization=>'Bearer alice'); $s->websocket_route($a2);
  $a2->{tx}->emit(message => fr(rennari_resume=>{session_id=>$sid, offset=>0}));
  is((sent_events($a2))->[-1], 'rennari_resumed', 'same identity resumes'); }

# mock
{ my $s=Mojo::Rennari::Server->new(mock=>1, logger=>$quiet); my $c=FakeC->new(); $s->websocket_route($c); ok(!$c->{tx}{closed}, 'mock opens'); %main::T=(); my $c2=FakeC->new(); $s->websocket_route($c2); is(Mojo::IOLoop->pending,0,'no timer'); }
ok(!grep { /a{40}|b{40}|user-secret/ } @$LOG, 'logs never contain the token');
done_testing;
