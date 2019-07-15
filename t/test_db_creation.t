#!/usr/bin/env bats

@test "PostgreSQL database creation test" {
    WORK_DIR="/tmp/tests"
    cd $WORK_DIR
    for test_dir in * ; do
			cd $test_dir
			cat command_line
			createdb reg
			psql reg < before.sql
			psql reg < after.sql
			psql reg < unsure.sql
			dropdb reg
			cd ..
		done
}
