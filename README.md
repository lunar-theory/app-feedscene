App::FeedScene version 0.10
===========================

App::FeedScene handles the server-side feed generation for the FeedScene iPad
application. It's written in Perl, and is designed to be run on one or more
`cron` jobs to harvest and transform feeds into a single Atom feed to be
downloaded by FeedScene.

INSTALLATION

To install this application, edit `conf/prod.yml` with your database connection
information, and then type the following:

    perl Build.PL
    ./Build --context prod
    ./Build
    ./Build db

Copyright
---------

Copyright (c) 2010 Kineticode, Inc. All rights reserved.
