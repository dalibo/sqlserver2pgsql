#!/usr/bin/env bats

@test "schema conversion test" {
  ./sqlserver2pgsql.pl -f regression/reg_tests.sql -b /tmp/before -a /tmp/after -u /tmp/unsure -k /tmp/kettle -sd 1 -sh 1 -sp 1 -su 1 -sw 1 -pd 1 -ph 1 -pp 1 -pu 1 -pw 2
}
