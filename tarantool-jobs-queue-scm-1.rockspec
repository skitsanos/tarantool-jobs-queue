package = 'tarantool-jobs-queue'
version = 'scm-1'

source = {
    url = 'git+https://github.com/skitsanos/tarantool-jobs-queue.git',
    branch = 'main',
}

description = {
    summary = 'A REST API for a Tarantool-backed jobs queue',
    homepage = 'https://github.com/skitsanos/tarantool-jobs-queue',
    license = 'MIT',
}

dependencies = {
    'lua >= 5.1',
    'http == 1.9.0',
}

build = {
    type = 'builtin',
    modules = {
        auth = 'src/auth.lua',
        persistence = 'src/persistence.lua',
        jobs = 'src/jobs.lua',
        migrations = 'src/migrations.lua',
    },
}
