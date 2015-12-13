###
Manage storage

CONFIGURATION:  see storage-config.md

SMC uses a tiered storage system.  The highest existing files are the "source of truth"
for the current state of the project.  If any actual files are at level n, they take
precedence over files at level n+1.

1. LIVE: The /projects/project_id directory compute server  (named "compute*") on
   which the project is sitting, as defined by the 'host' field in the projects
   table of the database.

2. SNAPSHOT: The /projects/project_id directory on a storage server (named "projects*"),
   as defined by the 'storage' field in the projects table.  Some files are
   excluded here (see the excludes function below).

3. BUP: The /bup/project_id/newest_timestamp directory on a storage server.
   This is a bup repository of snapshots of 2.  The project is the contents
   of master/latest/ (which is stripped so it equals the contents of projects/)

4. GCS: Google cloud storage path gs://smc-projects-bup/project_id/newest_timstamp,
   which is again a bup repository of snapshots of 2, with some superfulous files
   removed.  This gets copied to 3 and extracted.

5. OFFSITE: Offsite drive(s) -- bup repositories: smc-projects-bup/project_id/newest_timstamp


High level functions:

- close_TIER - saved tolower tier, then delete project from TIER
- open_TIER  - open on TIER using files from lower tier (assumes project not already open)
- save_TIER  - save project to TIER, from the tier above it.

Low level functions:
- delete_TIER - lower-level function that removes files from TIER with no checks or saves
- copy_TIER_to_TIER

NOTES:
  - save_BUP always saves to GCS as well, so there is no save_GCS.
###

BUCKET = 'smc-projects-bup'  # if given, will upload there using gsutil rsync

if process.env.USER != 'root'
    console.warn("WARNING: many functions in storage.coffee will not work if you aren't root!")

{join}      = require('path')
fs          = require('fs')
os          = require('os')

async       = require('async')
rmdir       = require('rimraf')
winston     = require('winston')

misc_node   = require('smc-util-node/misc_node')

misc        = require('smc-util/misc')
{defaults, required} = misc

# Set the log level
winston.remove(winston.transports.Console)
winston.add(winston.transports.Console, {level: 'debug', timestamp:true, colorize:true})

exclude = () ->
    return ("--exclude=#{x}" for x in misc.split('.sage/cache .sage/temp .trash .Trash .sagemathcloud .smc .node-gyp .cache .forever .snapshots *.sage-backup'))

# Low level function that save all changed files from a compute VM to a local path.
# This must be run as root.
copy_project_from_LIVE_to_SNAPSHOT = (opts) ->
    opts = defaults opts,
        project_id : required    # uuid
        host       : required    # hostname of compute server, e.g., 'compute2-us'
        max_size_G : 50
        delete     : true
        cb         : required
    dbg = (m) -> winston.debug("copy_project_from_LIVE_to_SNAPSHOT(project_id='#{opts.project_id}'): #{m}")
    dbg("host='#{opts.host}'")
    args = ['-axH', "--max-size=#{opts.max_size_G}G", "--ignore-errors"]
    if opts.delete
        args = args.concat(["--delete", "--delete-excluded"])
    else
        args.push('--update')
    args = args.concat(exclude())
    args = args.concat(['-e', 'ssh -T -c arcfour -o Compression=no -x  -o StrictHostKeyChecking=no'])
    source = "#{opts.host}:/projects/#{opts.project_id}/"
    target = "/projects/#{opts.project_id}/"
    args = args.concat([source, target])
    dbg("starting rsync...")
    start = misc.walltime()
    misc_node.execute_code
        command     : 'rsync'
        args        : args
        timeout     : 3600*2  # up to 2 hours...
        err_on_exit : true
        cb          : (err, output) ->
            if err and output?.exit_code == 24 or output?.exit_code == 23
                # exit code 24 = partial transfer due to vanishing files
                # exit code 23 = didn't finish due to permissions; this happens due to fuse mounts
                err = undefined
            dbg("...finished rsync -- time=#{misc.walltime(start)}s")#; #{misc.to_json(output)}")
            opts.cb(err)

copy_project_from_SNAPSHOT_to_LIVE = (opts) ->
    opts = defaults opts,
        project_id : required    # uuid
        host       : required    # hostname of computer, e.g., compute2-us
        cb         : required
    dbg = (m) -> winston.debug("copy_project_from_SNAPSHOT_to_LIVE(project_id='#{opts.project_id}'): #{m}")
    dbg("host='#{opts.host}'")
    args = ['-axH']
    args = args.concat(['-e', 'ssh -T -c arcfour -o Compression=no -x  -o StrictHostKeyChecking=no'])
    source = "/projects/#{opts.project_id}/"
    target = "#{opts.host}:/projects/#{opts.project_id}/"
    args = args.concat([source, target])
    dbg("starting rsync...")
    start = misc.walltime()
    misc_node.execute_code
        command     : 'rsync'
        args        : args
        timeout     : 10000
        verbose     : true
        err_on_exit : true
        cb          : (out...) ->
            dbg("finished rsync -- time=#{misc.walltime(start)}s")
            opts.cb(out...)

get_storage = (project_id, database, cb) ->
    dbg = (m) -> winston.debug("get_storage(project_id='#{project_id}'): #{m}")
    database.table('projects').get(project_id).pluck(['storage']).run (err, x) ->
        if err
            cb(err)
        else if not x?
            cb("no such project")
        else
            cb(undefined, x.storage?.host)

get_host_and_storage = (project_id, database, cb) ->
    dbg = (m) -> winston.debug("get_host_and_storage(project_id='#{project_id}'): #{m}")
    host = undefined
    storage = undefined
    async.series([
        (cb) ->
            dbg("determine project location info")
            database.table('projects').get(project_id).pluck(['storage', 'host']).run (err, x) ->
                if err
                    cb(err)
                else if not x?
                    cb("no such project")
                else
                    host    = x.host?.host
                    storage = x.storage?.host
                    if not host?
                        cb("project not currently open on a compute host")
                    else
                        cb()
        (cb) ->
            if storage?
                cb()
                return
            dbg("allocate storage host")
            database.table('storage_servers').pluck('host').run (err, x) ->
                if err
                    cb(err)
                else if not x? or x.length == 0
                    cb("no storage servers in storage_server table")
                else
                    # TODO: could choose based on free disk space
                    storage = misc.random_choice((a.host for a in x))
                    database.set_project_storage
                        project_id : project_id
                        host       : storage
                        cb         : cb
    ], (err) ->
        cb(err, {host:host, storage:storage})
    )

# Save project from compute VM to its assigned storage server.  Error
# if project not opened LIVE.
exports.save_SNAPSHOT = save_SNAPSHOT = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required    # uuid
        max_size_G : 50
        cb         : required
    dbg = (m) -> winston.debug("save_SNAPSHOT(project_id='#{opts.project_id}'): #{m}")
    host = undefined
    async.series([
        (cb) ->
            get_host_and_storage opts.project_id, opts.database, (err, x) ->
                if err
                    cb(err)
                else
                    {host, storage} = x
                    if storage != os.hostname()
                        cb("project is assigned to '#{storage}', but this server is '#{os.hostname()}'")
                    else
                        cb()
        (cb) ->
            dbg("do the save")
            copy_project_from_LIVE_to_SNAPSHOT
                project_id : opts.project_id
                host       : host
                cb         : cb
        (cb) ->
            dbg("save succeeded -- record in database")
            opts.database.update_project_storage_save
                project_id : opts.project_id
                cb         : cb
    ], (err) -> opts.cb(err))


###
Save all projects that have been modified in the last age_m minutes
which are stored on this machine.
If there are errors, then will get cb({project_id:'error...', ...})

To save(=rsync over) everything modified in the last week:

s = require('smc-hub/storage'); require('smc-hub/rethink').rethinkdb(hosts:['db0'],pool:1,cb:(err,db)->s.save_SNAPSHOT_age(database:db, age_m:60*24*7, cb:console.log))

###
exports.save_SNAPSHOT_age = (opts) ->
    opts = defaults opts,
        database : required
        age_m    : required  # save all projects with last_edited at most this long ago in minutes
        threads  : 5         # number of saves to do at once.
        cb       : required
    dbg = (m) -> winston.debug("save_all_projects(last_edited_m:#{opts.age_m}): #{m}")
    dbg()

    errors   = {}
    hostname = os.hostname()
    projects = undefined
    async.series([
        (cb) ->
            dbg("get all recently modified projects from the database")
            opts.database.recent_projects
                age_m : opts.age_m
                pluck : ['project_id', 'storage']
                cb    : (err, v) ->
                    if err
                        cb(err)
                    else
                        dbg("got #{v.length} recently modified projects")
                        # we should do this filtering on the server
                        projects = (x.project_id for x in v when x.storage?.host == hostname)
                        dbg("got #{projects.length} projects stored here")
                        cb()
        (cb) ->
            dbg("save each modified project")
            n = 0
            f = (project_id, cb) ->
                n += 1
                m = n
                dbg("#{m}/#{projects.length}: START")
                save_SNAPSHOT
                    project_id : project_id
                    database   : opts.database
                    cb         : (err) ->
                        dbg("#{m}/#{projects.length}: DONE  -- #{err}")
                        if err
                            errors[project_id] = err
                        cb()
            async.mapLimit(projects, opts.threads, f, cb)
        ], (err) ->
            opts.cb(if misc.len(errors) > 0 then errors)
    )

# Assuming LIVE is deleted, make sure project is properly saved to BUP,
# then delete from SNAPSHOT.
exports.close_SNAPSHOT = close_SNAPSHOT = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required
        cb         : required
    dbg = (m) -> winston.debug("close_SNAPSHOT(project_id='#{opts.project_id}'): #{m}")
    async.series([
        (cb) ->
            dbg('check that project is NOT currently opened LIVE')
            opts.database.get_project_host
                project_id : opts.project_id
                cb         : (err, x) ->
                    if err
                        cb(err)
                    else if x?.host?
                        cb("project must not be open LIVE")
                    else
                        cb()
        (cb) ->
            dbg('save project to BUP (and GCS)')
            save_BUP
                database    : opts.database
                project_id : opts.project_id
                cb         : cb
        (cb) ->
            dbg('saving to BUP succeeded; now deleting SNAPSHOT')
            delete_SNAPSHOT
                project_id : opts.project_id
                cb         : cb
    ], opts.cb)

delete_SNAPSHOT = (opts) ->
    opts = defaults opts,
        project_id : required
        cb         : required
    winston.debug("delete_SNAPSHOT('#{opts.project_id}')")
    rmdir("/projects/#{opts.project_id}", opts.cb)

delete_BUP = (opts) ->
    opts = defaults opts,
        project_id : required
        cb         : required
    winston.debug("delete_BUP('#{opts.project_id}')")
    rmdir("/bup/#{opts.project_id}", opts.cb)

# Assuming LIVE and SNAPSHOT are both deleted, sync BUP repo to GCS,
# then delete BUP from this machine.
exports.close_BUP = close_BUP = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required
        cb         : required
    dbg = (m) -> winston.debug("close_BUP(project_id='#{opts.project_id}'): #{m}")
    async.series([
        (cb) ->
            dbg('check that SNAPSHOT is deleted on this computer')
            fs.exists "/projects/#{opts.project_id}", (exists) ->
                if exists
                    cb("must first close SNAPSHOT")
                else
                    cb()
        (cb) ->
            dbg('check that BUP is available on this computer')
            fs.exists "/bup/#{opts.project_id}", (exists) ->
                if not exists
                    cb("no BUP on this host")
                else
                    cb()
        (cb) ->
            dbg('save BUP to GCS')
            copy_BUP_to_GCS
                project_id : opts.project_id
                cb         : cb
        (cb) ->
            dbg('saving BUP to GCS succeeded; now delete BUP')
            delete_BUP
                project_id : opts.project_id
                cb         : cb
    ], opts.cb)

# Make sure project is properly saved to SNAPSHOT, then delete from LIVE.
exports.close_LIVE = close_LIVE = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required
        cb         : required
    dbg = (m) -> winston.debug("close_LIVE(project_id='#{opts.project_id}'): #{m}")
    host = undefined
    async.series([
        (cb) ->
            dbg('figure out where project is currently opened')
            opts.database.get_project_host
                project_id : opts.project_id
                cb         : (err, x) ->
                    host = x?.host
                    cb(err)
        (cb) ->
            if not host?
                dbg('project not currently opened')
                cb()
                return
            dbg('do a last copy of the project to this server')
            copy_project_from_LIVE_to_SNAPSHOT
                project_id : opts.project_id
                host       : host
                cb         : cb
        (cb) ->
            if not host?
                cb(); return
            dbg('save succeeded: mark project host as not set in database')
            opts.database.unset_project_host
                project_id : opts.project_id
                cb         : cb
        (cb) ->
            if not host?
                cb(); return
            dbg("finally, actually deleting the project from '#{host}' to free disk space")
            delete_LIVE
                project_id : opts.project_id
                host       : host
                cb         : cb
    ], opts.cb)

# Low level function that removes project from a given compute server.  DANGEROUS, obviously.
delete_LIVE = (opts) ->
    opts = defaults opts,
        project_id : required
        host       : required  # hostname of compute server where project will be DELETED
        cb         : required
    # Do a check on the input, given how dangerous this command is!
    if not misc.is_valid_uuid_string(opts.project_id)
        opts.cb("project_id='#{opts.project_id}' is not a valid uuid")
        return
    if not misc.startswith(opts.host, 'compute')
        opts.cb("host='#{opts.host}' does not start with 'compute', which is suspicious")
        return
    target = "/projects/#{opts.project_id}"
    misc_node.execute_code
        command : 'ssh'
        args    : ["root@#{opts.host}", "rm -rf #{target}"]
        timeout : 1800
        cb      : opts.cb

# Open project on a given compute server (so copy from storage to compute server).
# Error if project is already open on a server according to the database.
exports.open_LIVE = open_LIVE = (opts) ->
    opts = defaults opts,
        database   : required
        host       : required  # hostname of compute server where project will be opened
        project_id : required
        cb         : required
    dbg = (m) -> winston.debug("open_LIVE(project_id='#{opts.project_id}', host='#{opts.host}'): #{m}")
    async.series([
        (cb) ->
            dbg('make sure project is not already opened somewhere')
            opts.database.get_project_host
                project_id : opts.project_id
                cb         : (err, x) ->
                    if err
                        cb(err)
                    else
                        if x?.host?
                            cb("project already opened")
                        else
                            cb()
        (cb) ->
            fs.exists "/projects/#{opts.project_id}", (exists) ->
                if exists
                    dbg("project is available locally in /projects directory")
                    cb()
                else
                    dbg("project is NOT available locally in /projects directory -- restore from bup archive (if one exists)")
                    exports.open_SNAPSHOT
                        database   : opts.database
                        project_id : opts.project_id
                        cb         : cb
        (cb) ->
            dbg("do the open")
            copy_project_from_SNAPSHOT_to_LIVE
                project_id : opts.project_id
                host       : opts.host
                cb         : cb
        (cb) ->
            dbg("open succeeded -- record in database")
            opts.database.set_project_host
                project_id : opts.project_id
                host       : opts.host
                cb         : cb
    ], opts.cb)

# Move project, which must be open on LIVE, from one compute server to another.
exports.move_project = move_project = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required
        target     : required
        cb         : required
    dbg = (m) -> winston.debug("move_project(project_id='#{opts.project_id}'): #{m}")
    source = undefined
    async.series([
        (cb) ->
            dbg('determine current location of project')
            opts.database.get_project_host
                project_id : opts.project_id
                cb         : (err, x) ->
                    if err
                        cb(err)
                    else
                        source = x?.host
                        if not source
                            cb("project not opened, so can't move")
                        else if source == opts.target
                            cb("project is already on '#{opts.target}'")
                        else
                            cb()
        (cb) ->
            dbg("copy the project")
            copy_project_from_one_compute_server_to_another
                project_id : opts.project_id
                source     : source
                target     : opts.target
                cb         : cb
        (cb) ->
            dbg("successfully copied the project, now setting host in database")
            opts.database.set_project_host
                project_id : opts.project_id
                host       : opts.target
                cb         : cb
        (cb) ->
            dbg("also, delete from the source to save space")
            delete_LIVE
                project_id : opts.project_id
                host       : source
                cb         : cb
    ], opts.cb)

# Low level function that copies a project from one compute server to another.
# We assume the target is empty (so no need for dangerous --delete).
copy_project_from_one_compute_server_to_another = (opts) ->
    opts = defaults opts,
        project_id : required
        source     : required
        target     : required
        cb         : required
    winston.debug("copy the project from '#{opts.source}' to '#{opts.target}'")
    # Do a check on the input, given how dangerous this command is!
    if not misc.is_valid_uuid_string(opts.project_id)
        opts.cb("project_id='#{opts.project_id}' is not a valid uuid")
        return
    for host in [opts.source, opts.target]
        if not misc.startswith(host, 'compute')
            opts.cb("host='#{host}' must start with 'compute'")
            return
    source = "/projects/#{opts.project_id}/"
    target = "#{opts.target}:/projects/#{opts.project_id}/"
    excludes = exclude().join(' ')

    misc_node.execute_code
        command : 'ssh'
        args    : ["root@#{opts.source}", "rsync -axH -e 'ssh -T -c arcfour -o Compression=no -x  -o StrictHostKeyChecking=no' #{excludes} #{source} #{target}"]
        timeout : 3600*2  # up to 2 hours...
        cb      : (err, output) ->
            if err and output?.exit_code == 24 or output?.exit_code == 23 # see copy_project_from_LIVE_to_SNAPSHOT
                err = undefined
            opts.cb(err)




###
Snapshoting projects using bup
###

###
Must run as root:

db = require('smc-hub/rethink').rethinkdb(hosts:['db0'],pool:1); s = require('smc-hub/storage');

# make sure everything from 2 years ago (or older) has a backup
s.save_BUP_age(database:db, min_age_m:2 * 60*24*365, age_m:1e8, time_since_last_backup_m:1e8, cb:(e)->console.log("DONE",e))

# make sure everything modified in the last week has at least one backup made within
# the last day (if it was backed up after last edited, it won't be backed up again)
s.save_BUP_age(database:db, age_m:7*24*60, time_since_last_backup_m:60*24, threads:1, cb:(e)->console.log("DONE",e))
###
exports.save_BUP_age = (opts) ->
    opts = defaults opts,
        database  : required
        age_m     : undefined  # if given, select projects at most this old
        min_age_m : undefined  # if given, selects only projects that are at least this old
        threads   : 1
        time_since_last_backup_m : undefined  # if given, only backup projects for which it has been at least this long since they were backed up
        cb        : required
    projects = undefined
    dbg = (m) -> winston.debug("save_BUP_age: #{m}")
    dbg("age_m=#{opts.age_m}; min_age_m=#{opts.min_age_m}; time_since_last_backup_m=#{opts.time_since_last_backup_m}")
    async.series([
        (cb) ->
            if opts.time_since_last_backup_m?
                opts.database.recent_projects
                    age_m     : opts.age_m
                    min_age_m : opts.min_age_m
                    pluck     : ['last_backup', 'project_id', 'last_edited']
                    cb        : (err, v) ->
                        if err
                            cb(err)
                        else
                            dbg("got #{v.length} recent projects")
                            projects = []
                            cutoff = misc.minutes_ago(opts.time_since_last_backup_m)
                            for x in v
                                if x.last_backup? and x.last_edited? and x.last_backup >= x.last_edited
                                    # no need to make another backup, since already have an up to date backup
                                    continue
                                if not x.last_backup? or x.last_backup <= cutoff
                                    projects.push(x.project_id)
                            dbg("of these recent projects, #{projects.length} DO NOT have a backup made within the last #{opts.time_since_last_backup_m} minutes")
                            cb()
            else
                opts.database.recent_projects
                    age_m     : opts.age_m
                    min_age_m : opts.min_age_m
                    cb        : (err, v) ->
                        projects = v
                        cb(err)
        (cb) ->
            dbg("making backup of #{projects.length} projects")
            save_BUP_many
                database : opts.database
                projects : projects
                threads  : opts.threads
                cb       : cb
        ], opts.cb)

save_BUP_many = (opts) ->
    opts = defaults opts,
        database : required
        projects : required
        threads  : 1
        cb       : required
    # back up a list of projects that are stored on this computer
    dbg = (m) -> winston.debug("save_BUP_many(projects.length=#{opts.projects.length}): #{m}")
    dbg("threads=#{opts.threads}")
    errors = {}
    n = 0
    done = 0
    f = (project_id, cb) ->
        n += 1
        m = n
        dbg("#{m}/#{opts.projects.length}: backing up #{project_id}")
        save_BUP
            database   : opts.database
            project_id : project_id
            cb         : (err) ->
                done += 1
                dbg("#{m}/#{opts.projects.length}: #{done} DONE #{project_id} -- #{err}")
                if done >= opts.projects.length
                    dbg("**COMPLETELY DONE!!**")
                if err
                    errors[project_id] = err
                cb()
    finish = ->
        if misc.len(errors) == 0
            opts.cb()
        else
            opts.cb(errors)
    async.mapLimit(opts.projects, opts.threads, f, finish)


# Make snapshot of project using bup to local cache, then
# rsync that repo to google cloud storage.  Records successful
# save in the database.  Must be run as root.
save_BUP = exports.save_BUP = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required
        cb         : required
    dbg = (m) -> winston.debug("save_BUP(project_id='#{opts.project_id}'): #{m}")
    dbg()
    exists = bup = undefined
    async.series([
        (cb) ->
            fs.exists join('/projects', opts.project_id), (_exists) ->
                # not an error -- this means project was never used at all (and saved)
                exists = _exists
                cb()
        (cb) ->
            if not exists
                cb(); return
            dbg("saving project to local bup repo")
            bup_save_project
                project_id    : opts.project_id
                cb            : (err, _bup) ->
                    if err
                        cb(err)
                    else
                        bup = _bup           # "/bup/#{project_id}/{timestamp}"
                        cb()
        (cb) ->
            if not exists
                cb(); return
            if not BUCKET
                cb(); return
            copy_BUP_to_GCS
                project_id : opts.project_id
                bup        : bup
                cb         :cb
        (cb) ->
            dbg("recording successful backup in database")
            opts.database.table('projects').get(opts.project_id).update(last_backup: new Date()).run(cb)
    ], (err) -> opts.cb(err))

copy_BUP_to_GCS = (opts) ->
    opts = defaults opts,
        project_id : required
        bup        : undefined     # optionally give path to specific bup repo with timestamp
        cb         : required
    dbg = (m) -> winston.debug("copy_BUP_to_GCS(project_id='#{opts.project_id}'): #{m}")
    dbg()
    bup = opts.bup
    async.series([
        (cb) ->
            if bup?
                cb(); return
            get_bup_path opts.project_id, (err, x) ->
                bup = x; cb(err)
        (cb) ->
            i = bup.indexOf(opts.project_id)
            if i == -1
                cb("bup path must contain project_id")
                return
            else
                bup1 = bup.slice(i)  # "#{project_id}/{timestamp}"
            async.parallel([
                (cb) ->
                    dbg("rsync'ing pack files")
                    # Upload new pack file objects -- don't use -c, since it would be very (!!) slow on these
                    # huge files, and isn't needed, since time stamps are enough.  We also don't save the
                    # midx and bloom files, since they also can be recreated from the pack files.
                    misc_node.execute_code
                        timeout : 2*3600
                        command : 'gsutil'
                        args    : ['-m', 'rsync', '-x', '.*\.bloom|.*\.midx', '-r', "#{bup}/objects/", "gs://#{BUCKET}/#{bup1}/objects/"]
                        cb      : cb
                (cb) ->
                    dbg("rsync'ing refs and logs files")
                    f = (path, cb) ->
                        # upload refs; using -c below is critical, since filenames don't change but content does (and timestamps aren't
                        # used by gsutil!).
                        misc_node.execute_code
                            timeout : 300
                            command : 'gsutil'
                            args    : ['-m', 'rsync', '-c', '-r', "#{bup}/#{path}/", "gs://#{BUCKET}/#{bup1}/#{path}/"]
                            cb      : cb
                    async.map(['refs', 'logs'], f, cb)
                    # NOTE: we don't save HEAD, since it is always "ref: refs/heads/master"
            ], cb)
        ], opts.cb)

get_bup_path = (project_id, cb) ->
    dir = "/bup/#{project_id}"
    fs.readdir dir, (err, files) ->
        if err
            cb(err)
        else
            files = files.sort()
            if files.length > 0
                bup = join(dir, files[files.length-1])
            cb(undefined, bup)

# this must be run as root.
bup_save_project = (opts) ->
    opts = defaults opts,
        project_id    : required
        cb            : required   # opts.cb(err, BUP_DIR)
    dbg = (m) -> winston.debug("bup_save_project(project_id='#{opts.project_id}'): #{m}")
    dbg()
    source = join('/projects', opts.project_id)
    dir = "/bup/#{opts.project_id}"
    bup = undefined # will be set below to abs path of newest bup repo
    async.series([
        (cb) ->
            dbg("create target bup repo")
            fs.exists dir, (exists) ->
                if exists
                    cb()
                else
                    fs.mkdir(dir, cb)
        (cb) ->
            dbg('ensure there is a bup repo')
            get_bup_path opts.project_id, (err, x) ->
                bup = x; cb(err)
        (cb) ->
            if bup?
                cb(); return
            dbg("must create bup repo")
            bup = join(dir, misc.date_to_snapshot_format(new Date()))
            fs.mkdir(bup, cb)
        (cb) ->
            dbg("init bup repo")
            misc_node.execute_code
                command : 'bup'
                args    : ['init']
                timeout : 120
                env     : {BUP_DIR:bup}
                cb      : cb
        (cb) ->
            dbg("index the project")
            misc_node.execute_code
                command : 'bup'
                args    : ['index', source]
                timeout : 60*30   # 30 minutes
                env     : {BUP_DIR:bup}
                cb      : cb
        (cb) ->
            dbg("save the bup snapshot")
            misc_node.execute_code
                command : 'bup'
                args    : ['save', source, '-n', 'master', '--strip']
                timeout : 60*60*2  # 2 hours
                env     : {BUP_DIR:bup}
                cb      : cb
        (cb) ->
            dbg('ensure that all backup files are readable by the salvus user (only user on this system)')
            misc_node.execute_code
                command : 'chmod'
                args    : ['a+r', '-R', bup]
                timeout : 60
                cb      : cb
    ], (err) ->
        opts.cb(err, bup)
    )

# Copy most recent bup archive of project to local bup cache, put the HEAD file in,
# then restore the most recent snapshot in the archive to the local projects path.
exports.open_SNAPSHOT = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required
        cb         : required
    dbg = (m) -> winston.debug("restore_project(project_id='#{opts.project_id}'): #{m}")
    dbg()
    async.series([
        (cb) ->
            dbg("update/get bup rep from google cloud storage")
            open_BUP
                project_id : opts.project_id
                database   : opts.database
                cb         : cb
        (cb) ->
            dbg("extract project")
            copy_BUP_to_SNAPSHOT
                project_id    : opts.project_id
                cb            : cb
        (cb) ->
            dbg("record that project is now stored here")
            opts.database.update_project_storage_save
                project_id : opts.project_id
                cb         : cb
    ], (err)->opts.cb(err))

# Extract most recent snapshot of project from local bup archive to a
# local directory.  bup archive is assumed to be in /bup/project_id/[timestamp].
copy_BUP_to_SNAPSHOT = (opts) ->
    opts = defaults opts,
        project_id    : required
        cb            : required
    dbg = (m) -> winston.debug("open_SNAPSHOT(project_id='#{opts.project_id}'): #{m}")
    dbg()
    outdir = "/projects/#{opts.project_id}"
    local_path = "/bup/#{opts.project_id}"
    bup = undefined
    async.series([
        (cb) ->
            fs.readdir local_path, (err, files) ->
                if err
                    cb(err)
                else
                    if files.length > 0
                        files.sort()
                        snapshot = files[files.length-1]  # newest snapshot
                        bup = join(local_path, snapshot)
                    cb()
        (cb) ->
            if not bup?
                # nothing to do -- no bup repos made yet
                cb(); return
            misc_node.execute_code
                command : 'bup'
                args    : ['restore', '--outdir', outdir, 'master/latest/']
                env     : {BUP_DIR:bup}
                cb      : cb
    ], (err)->opts.cb(err))

open_BUP = exports.open_BUP = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required
        cb         : required    # cb(err, path_to_bup_repo or undefined if no repo in cloud)
    dbg = (m) -> winston.debug("open_BUP(project_id='#{opts.project_id}'): #{m}")
    dbg()
    bup = source = undefined
    async.series([
        (cb) ->
            dbg("rsync bup repo from Google cloud storage -- first get list of available repos")
            misc_node.execute_code
                timeout : 120
                command : 'gsutil'
                args    : ['ls', "gs://smc-projects-bup/#{opts.project_id}"]
                cb      : (err, output) ->
                    if err
                        cb(err)
                    else
                        v = misc.split(output.stdout).sort()
                        if v.length > 0
                            source = v[v.length-1]   # like 'gs://smc-projects-bup/06e7df74-b68b-4370-9cdc-86aec577e162/2015-12-05-041330/'
                            dbg("most recent bup repo '#{source}'")
                            timestamp = require('path').parse(source).name
                            bup = "/bup/#{opts.project_id}/#{timestamp}"
                        else
                            dbg("WARNING: no known backups in GCS")
                        cb()
        (cb) ->
            if not source?
                # nothing to do -- nothing in GCS
                cb(); return
            dbg("determine local bup repos (already in /bup directory) -- these would take precedence if timestamp is as new")
            fs.readdir "/bup/#{opts.project_id}", (err, v) ->
                if err
                    # no directory
                    cb()
                else
                    v.sort()
                    if v.length > 0 and v[v.length-1] >= require('path').parse(source).name
                        dbg("newest local version is as new, so don't get anything from GCS.")
                        source = undefined
                    else
                        dbg("GCS is newer, will still get it")
                    cb()
        (cb) ->
            if not source?
                cb(); return
            misc_node.ensure_containing_directory_exists(bup+"/HEAD", cb)
        (cb) ->
            if not source?
                cb(); return
            async.parallel([
                (cb) ->
                    dbg("rsync'ing pack files")
                    fs.mkdir bup+'/objects', ->
                        misc_node.execute_code
                            timeout : 2*3600
                            command : 'gsutil'
                            args    : ['-m', 'rsync', '-r', "#{source}objects/", bup+'/objects/']
                            cb      : cb
                (cb) ->
                    dbg("rsync'ing refs files")
                    fs.mkdir bup+'/refs', ->
                        misc_node.execute_code
                            timeout : 2*3600
                            command : 'gsutil'
                            args    : ['-m', 'rsync', '-c', '-r', "#{source}refs/", bup+'/refs/']
                            cb      : cb
                (cb) ->
                    dbg("creating HEAD")
                    fs.writeFile(join(bup, 'HEAD'), 'ref: refs/heads/master', cb)
            ], (err) ->
                if err
                    # Attempt to remove the new bup repo we just tried and failed to get from GCS,
                    # so that next time we will try again.
                    rmdir bup, () ->
                        cb(err)  # but still report error
                else
                    cb()
            )
        (cb) ->
            dbg("record that project is now stored here")
            opts.database.update_project_storage_save
                project_id : opts.project_id
                cb         : cb
    ], (err) -> opts.cb(err, bup))

# Make sure everything modified in the last week has at least one backup made within
# the last day (if it was backed up after last edited, it won't be backed up again).
# For now we just run this (from the update_backups script) once per day to ensure
# we have useful offsite backups.
exports.update_BUP = () ->
    db = undefined
    async.series([
        (cb) ->
            require('./rethink').rethinkdb
                hosts : ['db0']
                pool  : 1
                cb    : (err, x) ->
                    db = x
                    cb(err)
        (cb) ->
            exports.save_BUP_age
                database                 : db
                age_m                    : 60*24*7
                time_since_last_backup_m : 60*24
                threads                  : 2
                cb                       : cb
    ], (err) ->
        winston.debug("!DONE! #{err}")
        process.exit(if err then 1 else 0)
    )

# Probably soon we won't need this since projects will get storage
# assigned right when they are created.
exports.assign_storage_to_all_projects = (database, cb) ->
    # Ensure that every project is assigned to some storage host.
    dbg = (m) -> winston.debug("assign_storage_to_all_projects: #{m}")
    dbg()
    projects = hosts = undefined
    async.series([
        (cb) ->
            dbg("get projects with no assigned storage")
            database.table('projects').filter((row)->row.hasFields({storage:true}).not()).pluck('project_id').run (err, v) ->
                dbg("get #{v?.length} projects")
                projects = v; cb(err)
        (cb) ->
            database.table('storage_servers').pluck('host').run (err, v) ->
                if err
                    cb(err)
                else
                    dbg("got hosts: #{misc.to_json(v)}")
                    hosts = (x.host for x in v)
                    cb()
        (cb) ->
            n = 0
            f = (project, cb) ->
                n += 1
                {project_id} = project
                host = misc.random_choice(hosts)
                dbg("#{n}/#{projects.length}: assigning #{project_id} to #{host}")
                database.get_project_storage  # do a quick check that storage isn't defined -- maybe slightly avoid race condition (we are being lazy)
                    project_id : project_id
                    cb         : (err, storage) ->
                        if err or storage?
                            cb(err)
                        else
                            database.set_project_storage
                                project_id : project_id
                                host       : host
                                cb         : cb
            async.mapLimit(projects, 10, f, cb)
    ], cb)

exports.update_SNAPSHOT = () ->
    # This should be run from the command line.
    # It checks that it isn't already running.  If not, it then
    # writes a pid file, copies everything over that was modified
    # since last time the pid file was written, then updates
    # all snapshots and exits.
    fs = require('fs')
    path = require('path')
    PID_FILE = '/home/salvus/.update_storage.pid'
    dbg = (m) -> winston.debug("update_storage: #{m}")
    last_pid = undefined
    last_run = undefined
    database = undefined
    async.series([
        (cb) ->
            dbg("read pid file #{PID_FILE}")
            fs.readFile PID_FILE, (err, data) ->
                if not err
                    last_pid = data.toString()
                cb()
        (cb) ->
            if last_pid?
                try
                    process.kill(last_pid, 0)
                    cb("previous process still running")
                catch e
                    dbg("good -- process not running")
                    cb()
            else
                cb()
        (cb) ->
            if last_pid?
                fs.stat PID_FILE, (err, stats) ->
                    if err
                        cb(err)
                    else
                        last_run = stats.mtime
                        cb()
            else
                last_run = misc.days_ago(1) # go back one day the first time
                cb()
        (cb) ->
            dbg("last run: #{last_run}")
            dbg("create new pid file")
            fs.writeFile(PID_FILE, "#{process.pid}", cb)
        (cb) ->
            # TODO: clearly this is hardcoded!
            require('smc-hub/rethink').rethinkdb
                hosts : ['db0']
                pool  : 1
                cb    : (err, db) ->
                    database = db
                    cb(err)
        (cb) ->
            exports.assign_storage_to_all_projects(database, cb)
        (cb) ->
            exports.save_SNAPSHOT_age
                database : database
                age_m    : (new Date() - last_run)/1000/60
                threads  : 5
                cb       : (err) ->
                    dbg("save_all_projects returned errors=#{misc.to_json(err)}")
                    cb()
        (cb) ->
            require('./rolling_snapshots').update_snapshots
                filesystem : 'projects'
                cb         : cb
    ], (err) ->
        dbg("finished -- err=#{err}")
        if err
            process.exit(1)
        else
            process.exit(0)
    )


exports.mount_snapshots_on_all_compute_vms_command_line = ->
    database = undefined
    async.series([
        (cb) ->
            require('smc-hub/rethink').rethinkdb
                hosts : ['db0']
                pool  : 1
                cb    : (err, db) ->
                    database = db; cb(err)
        (cb) ->
            exports.mount_snapshots_on_all_compute_vms
                database : database
                cb       : cb
    ], (err) ->
        if err
            process.exit(1)
        else
            winston.debug("SUCCESS!")
            process.exit(0)
    )

###
db = require('smc-hub/rethink').rethinkdb(hosts:['db0'], pool:1); s = require('smc-hub/storage'); 0;
s.mount_snapshots_on_all_compute_vms(database:db, cb:console.log)
###
exports.mount_snapshots_on_all_compute_vms = (opts) ->
    opts = defaults opts,
        database : required
        cb       : required   # cb() or cb({host:error, ..., host:error})
    dbg = (m) -> winston.debug("mount_snapshots_on_all_compute_vm: #{m}")
    server = os.hostname()  # name of this server
    hosts = undefined
    errors = {}
    async.series([
        (cb) ->
            dbg("check that sshd is setup with important restrictions (slightly limits damage in case compute machine is rooted)")
            fs.readFile '/etc/ssh/sshd_config', (err, data) ->
                if err
                    cb(err)
                else if data.toString().indexOf("Match User root") == -1
                    cb("Put this in /etc/ssh/sshd_config, then 'service sshd restart'!:\n\nMatch User root\n\tChrootDirectory /projects/.zfs/snapshot\n\tForceCommand internal-sftp")
                else
                    cb()
        (cb) ->
            dbg("query database for all compute vm's")
            opts.database.get_all_compute_servers
                cb : (err, v) ->
                    if err
                        cb(err)
                    else
                        hosts = (x.host for x in v)
                        cb()
        (cb) ->
            dbg("mounting snapshots on all compute vm's")
            errors = {}
            f = (host, cb) ->
                exports.mount_snapshots_on_compute_vm
                    host : host
                    cb   : (err) ->
                        if err
                            errors[host] = err
                        cb()
            async.map(hosts, f, cb)
    ], (err) ->
        if err
            opts.cb(err)
        else if misc.len(errors) > 0
            opts.cb(errors)
        else
            opts.cb()
    )

# ssh to the given compute server and setup an sshfs mount on
# it to this machine, if it isn't already setup.
# This must be run as root.
exports.mount_snapshots_on_compute_vm = (opts) ->
    opts = defaults opts,
        host : required     # hostname of compute server
        cb   : required
    server = os.hostname()  # name of this server
    mnt    = "/mnt/snapshots/#{server}/"
    remote = "fusermount -u -z #{mnt}; mkdir -p #{mnt}/; chmod a+rx /mnt/snapshots/ #{mnt}; sshfs -o ro,allow_other,default_permissions #{server}:/ #{mnt}/"
    winston.debug("mount_snapshots_on_compute_vm(host='#{opts.host}'): run this on #{opts.host}:   #{remote}")
    misc_node.execute_code
        command : 'ssh'
        args    : [opts.host, remote]
        timeout : 120
        cb      : opts.cb



###
Listen to database for requested storage actions and do them.  We listen for projects
that have this host assigned for storage.
###
process_update = (tasks, database, project) ->
    dbg = (m) -> winston.debug("process_update(project_id=#{project.project_id}): #{m}")
    if tasks[project.project_id]
        # definitely already running in this process
        return
    if project.storage_request.finished
        # definitely nothing to do -- it's finished
        return
    dbg(misc.to_json(project))
    dbg("START something!")
    query = database.table('projects').get(project.project_id)
    storage_request = project.storage_request
    action = storage_request.action
    update_db = () ->
        query.update(storage_request:database.r.literal(storage_request)).run()
    opts =
        database   : database
        project_id : project.project_id
        cb         : (err) ->
            tasks[project.project_id] = false
            storage_request.finished = new Date()
            if err
                storage_request.err = err
            update_db()
    func = err = undefined
    switch action
        when 'save'
            func = save_SNAPSHOT
        when 'close'
            func = close_LIVE
        when 'move'
            target = project.storage_request.target
            if not target?
                err = "move must specify target"
            else
                func = move_project
                opts.target = target
        when 'open'
            target = project.storage_request.target
            if not target?
                err = "open must specify target"
            else
                func = open_LIVE
                opts.host = target
        else
            err = "unknown action '#{action}'"
    if not func? and not err
        err = "bug in action handler"
    if err
        dbg(err)
        storage_request.finished = new Date()
        storage_request.err = err
        update_db()
    else
        dbg("doing action '#{action}")
        tasks[project.project_id] = true
        storage_request.started = new Date()
        update_db()
        func(opts)

exports.listen_to_db = (cb) ->
    host     = os.hostname()
    FIELDS   = ['project_id', 'storage_request', 'storage', 'host']
    projects = {}  # map from project_id to object
    query    = undefined
    database = undefined
    tasks    = {}
    dbg = (m) -> winston.debug("listener: #{m}")
    dbg()
    if process.env.USER != 'root'
        dbg("you must be root!")
        cb(true)
        return
    async.series([
        (cb) ->
            dbg("connect to database")
            require('smc-hub/rethink').rethinkdb
                hosts : ['db0']
                pool  : 1
                cb    : (err, db) ->
                    database = db
                    cb(err)
        (cb) ->
            dbg("create synchronized table")

            # Get every project assigned to this host that has done a storage request starting within the last hour.
            age   = misc.hours_ago(1)
            query = database.table('projects').between([host, age], [host, database.r.maxval], index:'storage_request').pluck(FIELDS...)
            database.synctable
                query : query
                cb    : (err, synctable) ->
                    if err
                        cb(err)
                    else
                        dbg("initialized synctable with #{synctable.get().size} projects")
                        # process all recent projects
                        synctable.get().map (x, project_id) ->
                            process_update(tasks, database, x.toJS())
                        # process any time a project changes
                        synctable.on 'change', (project_id) ->
                            x = synctable.get(project_id)
                            if x?
                                process_update(tasks, database, x.toJS())
                        cb()
    ], (err) =>
        if err
            dbg("error -- #{err}")
            process.exit(1)
    )



