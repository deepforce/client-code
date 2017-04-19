
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

# NB: use of this module involves substantial persistent use of disk space.
# Don't even think about it unless you have a couple og GB extra (at least)
# you can devote to this module's storage.

# For now, only tests C locale upgrades.

package PGBuild::Modules::TestUpgradeXversion;

use PGBuild::Options;
use PGBuild::SCM;

use Data::Dumper;
use File::Copy;
use File::Path;
use File::Basename;

use strict;

use vars qw($VERSION); $VERSION = 'REL_4.19';

my $hooks = {

    #    'checkout' => \&checkout,
    #    'setup-target' => \&setup_target,
    'need-run' => \&need_run,

    #    'configure' => \&configure,
    #    'build' => \&build,
    'locale-end' => \&installcheck,

    #    'check' => \&check,
    #    'cleanup' => \&cleanup,
};

sub setup
{
    my $class = __PACKAGE__;

    my $buildroot = shift; # where we're building
    my $branch = shift; # The branch of Postgres that's being built.
    my $conf = shift;  # ref to the whole config object
    my $pgsql = shift; # postgres build dir

    return if $from_source;

    my $upgrade_install_root =
      $conf->{upgrade_install_root} || "$buildroot/upgrade";

    my $self  = {
        buildroot => $buildroot,
        pgbranch=> $branch,
        bfconf => $conf,
        pgsql => $pgsql,
        upgrade_install_root =>	$upgrade_install_root,
    };
    bless($self, $class);

    main::register_module_hooks($self,$hooks);

}

sub need_run
{
    my $self = shift;
    my $need_run_ref = shift;
    my $upgrade_install_root = $self->{upgrade_install_root};
    my $upgrade_loc = "$upgrade_install_root/$self->{pgbranch}";
    $$need_run_ref = 1 unless -d $upgrade_loc;
}

sub setinstenv
{
    my $self = shift;
    my $installdir = shift;
    my $save_env = shift || {};

    # first restore environment from what was saved

    if (exists $save_env->{LD_LIBRARY_PATH})
    {
        $ENV{LD_LIBRARY_PATH} = $save_env->{LD_LIBRARY_PATH};
    }
    else
    {
        delete $ENV{LD_LIBRARY_PATH};
    }
    if (exists $save_env->{DYLD_LIBRARY_PATH})
    {
        $ENV{DYLD_LIBRARY_PATH} = $save_env->{DYLD_LIBRARY_PATH};
    }
    else
    {
        delete $ENV{DYLD_LIBRARY_PATH};
    }
    if (exists $save_env->{PATH})
    {
        $ENV{PATH} =  $save_env->{PATH};
    }

    # now adjust it to point to new dir

    if (my $ldpath = $ENV{LD_LIBRARY_PATH})
    {
        $ENV{LD_LIBRARY_PATH}="$installdir/lib:$ldpath";
    }
    else
    {
        $ENV{LD_LIBRARY_PATH}="$installdir/lib";
    }
    if (my $ldpath = $ENV{DYLD_LIBRARY_PATH})
    {
        $ENV{DYLD_LIBRARY_PATH}="$installdir/lib:$ldpath";
    }
    else
    {
        $ENV{DYLD_LIBRARY_PATH}="$installdir/lib";
    }
    if ($self->{pgconf}->{using_msvc})
    {
        $ENV{PATH} = "$installdir/bin;$ENV{PATH}";
    }
    else
    {
        $ENV{PATH} = "$installdir/bin:$ENV{PATH}";
    }

}

sub installcheck
{

    # this is called after base installcheck has run, which in turn
    # is after both base install and base contrib install have run,
    # so we have everything we should need.

    my $self = shift;
    my $locale = shift;
    return unless $locale eq 'C';

    return unless main::step_wanted('pg_upgrade-xversion-check');

    # localize any environment changes so they don't leak to calling code.

    my $save_env = eval Dumper(\%ENV);

    local %ENV = %ENV;

    print main::time_str(), "saving files for cross-version upgrade check\n"
      if	$verbose;

    my $upgrade_install_root = $self->{upgrade_install_root};
    my $install_loc = "$self->{buildroot}/$self->{pgbranch}/inst";
    my $upgrade_loc = "$upgrade_install_root/$self->{pgbranch}";
    my $installdir = "$upgrade_loc/inst";

    mkdir  $upgrade_install_root unless -d  $upgrade_install_root;

    rmtree($upgrade_loc);

    mkdir  $upgrade_loc;

    system(
        qq{cp -r "$install_loc" "$installdir" >"$upgrade_loc/save.log" 2>&1});

    # at some stage we stopped installing regress.so
    copy "$install_loc/../pgsql.build/src/test/regress/regress.so",
      "$installdir/lib/postgresql/regress.so"
      unless (-e "$installdir/lib/postgresql/regress.so");

    # keep a copy of installed database
    # to test it against, but we still need to move the regression
    # libraries.

    setinstenv($self, $installdir, $save_env);

    # start the server

    system("$installdir/bin/pg_ctl -D $installdir/data-C -o '-F' "
          ."-l '$upgrade_loc/db.log' -w start >'$upgrade_loc/ctl.log' 2>&1");

    # fix the regression database so its functions point to $libdir rather than
    # the source directory, which won't persist past this build.

    my $sql =
      'select probin::text from pg_proc where probin not like $$$libdir%$$';

    my @regresslibs = `psql -A -X -t -c '$sql' regression`;

    chomp @regresslibs;

    my %regresslibs = map { $_ => 1 } @regresslibs;

    foreach my $lib (keys %regresslibs)
    {
        my $dest = "$installdir/lib/postgresql/" . basename($lib);
        copy($lib,$dest);
        die "cannot find $dest (from $lib)" unless -e $dest;
        chmod 0755, $dest;
    }

    $sql = q{
               update pg_proc set probin =
                  regexp_replace(probin,$$.*/$$,$$$libdir/$$)
               where probin not like $$$libdir/%$$ returning proname,probin;
             };

    $sql =~ s/\n//g;

    my $opsql = "drop operator if exists public.=> (bigint, NONE)";
    system("$installdir/bin/psql -A -X -t -c '$opsql' regression "
          .">> '$upgrade_loc/fix.log' 2>&1");
    if ($self->{pgbranch} eq 'REL9_1_STABLE')
    {
        $opsql = "alter extension hstore drop operator => (text, text)";
        system("$installdir/bin/psql -A -X -t -c '$opsql' "
              ."contrib_regression_hstore >> '$upgrade_loc/fix.log' 2>&1");
        $opsql = 'drop  operator if exists "public".=> (text, text)';
        system("$installdir/bin/psql -A -X -t -c '$opsql' "
              ."contrib_regression_hstore >> '$upgrade_loc/fix.log' 2>&1");
    }
    system("$installdir/bin/psql -A -X -t -c '$sql' regression "
          .">> '$upgrade_loc/fix.log' 2>&1");
    system("$installdir/bin/psql -A -X -t -c '$sql' contrib_regression "
          .">> '$upgrade_loc/fix.log' 2>&1");
    if ($self->{pgbranch} ge 'REL9_5' || $self->{pgbranch} eq 'HEAD')
    {
        system(
            "$installdir/bin/psql -A -X -t -c '$sql' contrib_regression_dblink "
              .">> '$upgrade_loc/fix.log' 2>&1");
    }

    # disable modules known to cause pg_upgrade to fail

    foreach my $bad_module (
        "test_ddl_parse",

        #							"hstore_plpython2","ltree_plpython2",
        #							"hstore_plpython3","ltree_plpython3"
      )
    {
        system( "$installdir/bin/psql -A "
              . "-c 'drop database if exists contrib_regression_$bad_module' postgres"
              . ">> '$upgrade_loc/fix.log' 2>&1");
    }

    system("pg_ctl -D $installdir/data-C -w stop "
          .">> '$upgrade_loc/ctl.log' 2>&1");

    # ok, we now have the persistent copy of all branches we can use
    # to test upgrading from

    my $dconfig = `$installdir/bin/pg_config --configure`;
    my $dport = $dconfig =~ /--with-pgport=(\d+)/ ? $1 : 5432;

    # %ENV = %$save_env;

    foreach my $other_branch (
        sort {$a =~ "HEAD" ? 999 : $b =~ "HEAD" ? -999 : $a cmp $b  }
        glob("$upgrade_install_root/*"))
    {
        my $oversion = basename $other_branch;

        next unless -d $other_branch;

        next
          unless (($self->{pgbranch} eq 'HEAD')
            || ($oversion ne 'HEAD' && $oversion le $self->{pgbranch}));

        print main::time_str(),
          "checking upgrade from $oversion to $self->{pgbranch} ...\n"
          if	$verbose;

        rmtree "$other_branch/inst/upgrade_test";
        my $testcmd = qq{
              cp -r "$other_branch/inst/data-C"
                    "$other_branch/inst/upgrade_test"
              > '$upgrade_loc/$oversion-copy.log' 2>&1
        };
        $testcmd =~ s/\n//g;
        system $testcmd;

        setinstenv($self, "$other_branch/inst", $save_env);

        my $sconfig = `$other_branch/inst/bin/pg_config --configure`;
        my $sport = $sconfig =~ /--with-pgport=(\d+)/ ? $1 : 5432;

        system("$other_branch/inst/bin/pg_ctl -D "
              ."$other_branch/inst/upgrade_test -o '-F' -l "
              ."$other_branch/inst/dump-$self->{pgbranch}.log -w start "
              .">> '$upgrade_loc/ctl.log' 2>&1");

        # use the NEW pg_dumpall so we're comparing apples with apples.
        setinstenv($self, "$installdir", $save_env);
        system("$installdir/bin/pg_dumpall -p $sport -f "
              ."$upgrade_loc/origin-$oversion.sql "
              .">'$upgrade_loc/$oversion-dump1.log' 2>&1");
        setinstenv($self, "$other_branch/inst", $save_env);

        system("$other_branch/inst/bin/pg_ctl -D "
              ."$other_branch/inst/upgrade_test -w stop "
              .">> '$upgrade_loc/ctl.log' 2>&1");

        # %ENV = %$save_env;

        setinstenv($self,$installdir, $save_env);

        system("initdb -U buildfarm --locale=C "
              ."$installdir/$oversion-upgrade "
              ."> '$upgrade_loc/initdb.log' 2>&1");

        if ($oversion ge 'REL9_5_STABLE' || $oversion eq 'HEAD')
        {
            my $handle;
            open($handle,">>$installdir/$oversion-upgrade/postgresql.conf");
            print $handle "shared_preload_libraries = 'dummy_seclabel'\n";
            close $handle;
        }

        system("cd $installdir && pg_upgrade "
              ."--old-port=$sport "
              ."--new-port=$dport "
              ."--old-datadir=$other_branch/inst/upgrade_test "
              ."--new-datadir=$installdir/$oversion-upgrade "
              ."--old-bindir=$other_branch/inst/bin "
              ."--new-bindir=$installdir/bin "
              .">> '$upgrade_loc/upgrade.log' 2>&1");

        system("pg_ctl -D $installdir/$oversion-upgrade -l "
              ."$installdir/upgrade_log -w start "
              .">> '$upgrade_loc/ctl.log' 2>&1");

        system("cd $installdir && sh ./analyze_new_cluster.sh "
              ."> '$upgrade_loc/$oversion-analyse.log' 2>&1 ")
          if -e "$installdir/analyze_new_cluster.sh";

        system("pg_dumpall -f "
              ."$upgrade_loc/converted-$oversion-to-$self->{pgbranch}.sql");

        system("pg_ctl -D $installdir/$oversion-upgrade -w stop "
              .">> '$upgrade_loc/ctl.log'");

        system("cd $installdir && sh ./delete_old_cluster.sh")
          if -e "$installdir/delete_old_cluster.sh";

        foreach my $dumplog (glob("$installdir/pg_upgrade*"))
        {
            my $bl = basename $dumplog;
            rename $dumplog,"$installdir/$oversion-$bl";
        }

=comment

       [andrew@emma upgrade]$ find . -name dumpdiff* -print | xargs wc -l
   11 ./HEAD/inst/dumpdiff-REL9_2_STABLE
   11 ./HEAD/inst/dumpdiff-REL9_1_STABLE
  125 ./HEAD/inst/dumpdiff-REL9_0_STABLE
    0 ./REL9_2_STABLE/inst/dumpdiff-REL9_1_STABLE
  116 ./REL9_2_STABLE/inst/dumpdiff-REL9_0_STABLE
  116 ./REL9_1_STABLE/inst/dumpdiff-REL9_0_STABLE
                REL9_4_STABLE => 303,

=cut

        #target    source
        my $expected_difflines = {
            HEAD => {
                REL9_1_STABLE => 1175,
                REL9_2_STABLE => 1346,
                REL9_3_STABLE => 610,
                REL9_4_STABLE => 644,
                REL9_5_STABLE => 780,
                REL9_6_STABLE => 0,
            },
            REL9_6_STABLE => {
                REL9_1_STABLE => 1175,
                REL9_2_STABLE => 1346,
                REL9_3_STABLE => 610,
                REL9_4_STABLE => 644,
                REL9_5_STABLE => 780,
            },
            REL9_5_STABLE => {
                REL9_1_STABLE => 672,
                REL9_2_STABLE => 770,
                REL9_3_STABLE => 51,
                REL9_4_STABLE => 51,
            },
            REL9_4_STABLE => {
                REL9_1_STABLE => 643,
                REL9_2_STABLE => 741,
                REL9_3_STABLE => 0,
            },
            REL9_3_STABLE => {
                REL9_1_STABLE => 643,
                REL9_2_STABLE => 741,
            },
            REL9_2_STABLE => {
                REL9_1_STABLE => 0,
            },
        };

        system("diff -I '^-- ' -u $upgrade_loc/origin-$oversion.sql "
              ."$upgrade_loc/converted-$oversion-to-$self->{pgbranch}.sql "
              ."> $upgrade_loc/dumpdiff-$oversion 2>&1");
        my $difflines = `wc -l < $upgrade_loc/dumpdiff-$oversion`;
        chomp($difflines);

=junk
		
        my $expected = $expected_difflines->{$self->{pgbranch}}->{$oversion} || 0;


        if ($difflines == $expected)
        {
            print "***SUCCESS!\n";
        }
        else
        {
            print
              "dumps $upgrade_loc/origin-$oversion.sql ",
              "$upgrade_loc/converted-$oversion-to-$self->{pgbranch}.sql ",
              "- expected $expected got $difflines of diff\n";
        }

=cut

        # the above is all really a crock. If the versions match we should
        # expect 0 diffs if not we heuristically allow up to 2000 lines
        # of diff

        if (  ($oversion ne $self->{pgbranch} && $difflines < 2000)
            ||($oversion eq $self->{pgbranch}) && $difflines == 0)
        {
            print "***SUCCESS!\n";
        }
        else
        {
            print "FAILURE: $upgrade_loc/origin-$oversion.sql to ",
              "$upgrade_loc/converted-$oversion-to-$self->{pgbranch}.sql ",
              " contains too may lines of diff: $difflines\n";
        }

        rmtree("$installdir/$oversion-upgrade");

    }
}

1;
