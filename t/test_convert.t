#!/usr/bin/env bats

@test "schema conversion test" {
  WORK_DIR="/tmp/tests"

  # we must add the KETTLE_EMPTY_STRING_DIFFERS_FROM_NULL=Y in kettle conf file
  if [ ! -d ~/.kettle ]; then
			mkdir ~/.kettle
  fi
  if [ ! -f ~/.kettle/kettle.properties ]; then
			touch ~/.kettle/kettle.properties
  fi
  if [ -z $(grep "KETTLE_EMPTY_STRING_DIFFERS_FROM_NULL=Y" ~/.kettle/kettle.properties) ]; then
			echo -e "\n# This line was added for sqlserver2pgsql tests" >> ~/.kettle/kettle.properties
			echo -e "KETTLE_EMPTY_STRING_DIFFERS_FROM_NULL=Y" >> ~/.kettle/kettle.properties
  fi
	
  # create the array of command to try
  options_to_try=( "-i" "-nr" "-num" "-validate_constraints=after" )
  declare -a many_combinations=("blank ")
	
  for option_to_try in ${options_to_try[@]} ; do
		for existing_combination in ${many_combinations[@]}; do
  		all_combinations+="${option_to_try}_sep_${existing_combination} "
		done
  done
  declare -a all_combinations=many_combinations
	for existing_combination in ${all_combinations[@]}; do
 		all_combinations+="-keep_identifier_case_sep_${existing_combination} "
	done

  # clear the possible leftovers
  if [ -d $WORK_DIR ]; then
			rm -rf $WORK_DIR
  fi
  mkdir -p $WORK_DIR
	
  # run the sqlserver2pgsql script for all files and confs
  declare -i test_nb=1
  for reg_file in regression/*.sql ; do
		for option in ${all_combinations[@]} ; do
			CURRENT_DIR=$WORK_DIR/$test_nb
			mkdir -p $CURRENT_DIR
			real_option=$(echo $option | sed 's/blank//' | sed 's/_sep_/ /g')
			command_line="./sqlserver2pgsql.pl -f $reg_file -b $CURRENT_DIR/before.sql -a $CURRENT_DIR/after.sql -u $CURRENT_DIR/unsure.sql -k $CURRENT_DIR/kettle -sd 1 -sh 1 -sp 1 -su 1 -sw 1 -pd 1 -ph 1 -pp 1 -pu 1 -pw 2 $real_option"
			echo $command_line > $CURRENT_DIR/command_line
			eval $command_line > $CURRENT_DIR/command_output 2>&1
			test_nb+=1
		done
  done
  for reg_file in regression/basic_test/*.sql ; do
		for option in ${many_combinations[@]} ; do
			CURRENT_DIR=$WORK_DIR/$test_nb
			mkdir -p $CURRENT_DIR
			real_option=$(echo $option | sed 's/blank//' | sed 's/_sep_/ /g')
			command_line="./sqlserver2pgsql.pl -f $reg_file -b $CURRENT_DIR/before.sql -a $CURRENT_DIR/after.sql -u $CURRENT_DIR/unsure.sql -k $CURRENT_DIR/kettle -sd 1 -sh 1 -sp 1 -su 1 -sw 1 -pd 1 -ph 1 -pp 1 -pu 1 -pw 2 $real_option"
			echo $command_line > $CURRENT_DIR/command_line
			eval $command_line > $CURRENT_DIR/command_output 2>&1
			test_nb+=1
		done
  done
}
