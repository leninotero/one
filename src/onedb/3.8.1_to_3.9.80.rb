# -------------------------------------------------------------------------- #
# Copyright 2002-2012, OpenNebula Project Leads (OpenNebula.org)             #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

require 'set'
require "rexml/document"
include REXML

class String
    def red
        colorize(31)
    end

private

    def colorize(color_code)
        "\e[#{color_code}m#{self}\e[0m"
    end
end

module Migrator
    def db_version
        "3.9.80"
    end

    def one_version
        "OpenNebula 3.9.80"
    end

    def up

        ########################################################################
        # Add Cloning Image ID collection to Images
        ########################################################################

        counters = {}
        counters[:image] = {}

        # Init image counters
        @db.fetch("SELECT oid,body FROM image_pool") do |row|
            if counters[:image][row[:oid]].nil?
                counters[:image][row[:oid]] = {
                    :clones => Set.new
                }
            end

            doc = Document.new(row[:body])

            doc.root.each_element("CLONING_ID") do |e|
                img_id = e.text.to_i

                if counters[:image][img_id].nil?
                    counters[:image][img_id] = {
                        :clones => Set.new
                    }
                end

                counters[:image][img_id][:clones].add(row[:oid])
            end
        end

        ########################################################################
        # Image
        #
        # IMAGE/CLONING_OPS
        # IMAGE/CLONES/ID
        ########################################################################

        @db.run "CREATE TABLE image_pool_new (oid INTEGER PRIMARY KEY, name VARCHAR(128), body TEXT, uid INTEGER, gid INTEGER, owner_u INTEGER, group_u INTEGER, other_u INTEGER, UNIQUE(name,uid) );"

        @db[:image_pool].each do |row|
            doc = Document.new(row[:body])

            oid = row[:oid]

            n_cloning_ops = counters[:image][oid][:clones].size

            # Rewrite number of clones
            doc.root.each_element("CLONING_OPS") { |e|
                if e.text != n_cloning_ops.to_s
                    warn("Image #{oid} CLONING_OPS has #{e.text} \tis\t#{n_cloning_ops}")
                    e.text = n_cloning_ops
                end
            }

            # re-do list of Images cloning this one
            clones_new_elem = doc.root.add_element("CLONES")

            counters[:image][oid][:clones].each do |id|
                clones_new_elem.add_element("ID").text = id.to_s
            end

            row[:body] = doc.to_s

            # commit
            @db[:image_pool_new].insert(row)
        end

        # Rename table
        @db.run("DROP TABLE image_pool")
        @db.run("ALTER TABLE image_pool_new RENAME TO image_pool")

        ########################################################################
        # Feature #1617
        # New datastore, 2 "files"
        # DATASTORE/SYSTEM is now DATASTORE/TYPE
        ########################################################################

        @db.run "ALTER TABLE datastore_pool RENAME TO old_datastore_pool;"
        @db.run "CREATE TABLE datastore_pool (oid INTEGER PRIMARY KEY, name VARCHAR(128), body TEXT, uid INTEGER, gid INTEGER, owner_u INTEGER, group_u INTEGER, other_u INTEGER, UNIQUE(name));"

        @db.fetch("SELECT * FROM old_datastore_pool") do |row|
            doc = Document.new(row[:body])

            type = "0"  # IMAGE_DS

            system_elem = doc.root.delete_element("SYSTEM")

            if ( !system_elem.nil? && system_elem.text == "1" )
                type = "1"  # SYSTEM_DS
            end

            doc.root.add_element("TYPE").text = type

            doc.root.each_element("TEMPLATE") do |e|
                e.delete_element("SYSTEM")
                e.add_element("TYPE").text = type == "0" ? "IMAGE_DS" : "SYSTEM_DS"
            end

            @db[:datastore_pool].insert(
                :oid        => row[:oid],
                :name       => row[:name],
                :body       => doc.root.to_s,
                :uid        => row[:uid],
                :gid        => row[:gid],
                :owner_u    => row[:owner_u],
                :group_u    => row[:group_u],
                :other_u    => row[:other_u])
        end

        @db.run "DROP TABLE old_datastore_pool;"


        user_0_name = "oneadmin"

        @db.fetch("SELECT name FROM user_pool WHERE oid=0") do |row|
            user_0_name = row[:name]
        end

        group_0_name = "oneadmin"

        @db.fetch("SELECT name FROM group_pool WHERE oid=0") do |row|
            group_0_name = row[:name]
        end

        base_path = "/var/lib/one/datastores/2"

        @db.fetch("SELECT body FROM datastore_pool WHERE oid=0") do |row|
            doc = Document.new(row[:body])

            doc.root.each_element("BASE_PATH") do |e|
                base_path = e.text
                base_path[-1] = "2"
            end
        end

        @db.run "INSERT INTO datastore_pool VALUES(2,'files','<DATASTORE><ID>2</ID><UID>0</UID><GID>0</GID><UNAME>#{user_0_name}</UNAME><GNAME>#{group_0_name}</GNAME><NAME>files</NAME><PERMISSIONS><OWNER_U>1</OWNER_U><OWNER_M>1</OWNER_M><OWNER_A>0</OWNER_A><GROUP_U>1</GROUP_U><GROUP_M>0</GROUP_M><GROUP_A>0</GROUP_A><OTHER_U>1</OTHER_U><OTHER_M>0</OTHER_M><OTHER_A>0</OTHER_A></PERMISSIONS><DS_MAD>fs</DS_MAD><TM_MAD>ssh</TM_MAD><BASE_PATH>#{base_path}</BASE_PATH><TYPE>2</TYPE><DISK_TYPE>0</DISK_TYPE><CLUSTER_ID>-1</CLUSTER_ID><CLUSTER></CLUSTER><IMAGES></IMAGES><TEMPLATE><DS_MAD><![CDATA[fs]]></DS_MAD><TM_MAD><![CDATA[ssh]]></TM_MAD><TYPE><![CDATA[FILE_DS]]></TYPE></TEMPLATE></DATASTORE>',0,0,1,1,1);"


        ########################################################################
        # Feature #1611: Default quotas
        ########################################################################

        @db.run("CREATE TABLE IF NOT EXISTS system_attributes (name VARCHAR(128) PRIMARY KEY, body TEXT)")
        @db.run("INSERT INTO system_attributes VALUES('DEFAULT_GROUP_QUOTAS','<DEFAULT_GROUP_QUOTAS><DATASTORE_QUOTA></DATASTORE_QUOTA><NETWORK_QUOTA></NETWORK_QUOTA><VM_QUOTA></VM_QUOTA><IMAGE_QUOTA></IMAGE_QUOTA></DEFAULT_GROUP_QUOTAS>');")
        @db.run("INSERT INTO system_attributes VALUES('DEFAULT_USER_QUOTAS','<DEFAULT_USER_QUOTAS><DATASTORE_QUOTA></DATASTORE_QUOTA><NETWORK_QUOTA></NETWORK_QUOTA><VM_QUOTA></VM_QUOTA><IMAGE_QUOTA></IMAGE_QUOTA></DEFAULT_USER_QUOTAS>');")


        @db.run "ALTER TABLE user_pool RENAME TO old_user_pool;"
        @db.run "CREATE TABLE user_pool (oid INTEGER PRIMARY KEY, name VARCHAR(128), body TEXT, uid INTEGER, gid INTEGER, owner_u INTEGER, group_u INTEGER, other_u INTEGER, UNIQUE(name));"

        # oneadmin does not have quotas
        @db.fetch("SELECT * FROM old_user_pool WHERE oid=0") do |row|
            @db[:user_pool].insert(
                :oid        => row[:oid],
                :name       => row[:name],
                :body       => row[:body],
                :uid        => row[:oid],
                :gid        => row[:gid],
                :owner_u    => row[:owner_u],
                :group_u    => row[:group_u],
                :other_u    => row[:other_u])
        end

        @db.fetch("SELECT * FROM old_user_pool WHERE oid>0") do |row|
            doc = Document.new(row[:body])

            set_default_quotas(doc)

            @db[:user_pool].insert(
                :oid        => row[:oid],
                :name       => row[:name],
                :body       => doc.root.to_s,
                :uid        => row[:oid],
                :gid        => row[:gid],
                :owner_u    => row[:owner_u],
                :group_u    => row[:group_u],
                :other_u    => row[:other_u])
        end

        @db.run "DROP TABLE old_user_pool;"


        @db.run "ALTER TABLE group_pool RENAME TO old_group_pool;"
        @db.run "CREATE TABLE group_pool (oid INTEGER PRIMARY KEY, name VARCHAR(128), body TEXT, uid INTEGER, gid INTEGER, owner_u INTEGER, group_u INTEGER, other_u INTEGER, UNIQUE(name));"


        # oneadmin group does not have quotas
        @db.fetch("SELECT * FROM old_group_pool WHERE oid=0") do |row|
            @db[:group_pool].insert(
                :oid        => row[:oid],
                :name       => row[:name],
                :body       => row[:body],
                :uid        => row[:oid],
                :gid        => row[:gid],
                :owner_u    => row[:owner_u],
                :group_u    => row[:group_u],
                :other_u    => row[:other_u])
        end

        @db.fetch("SELECT * FROM old_group_pool WHERE oid>0") do |row|
            doc = Document.new(row[:body])

            set_default_quotas(doc)

            @db[:group_pool].insert(
                :oid        => row[:oid],
                :name       => row[:name],
                :body       => doc.root.to_s,
                :uid        => row[:oid],
                :gid        => row[:gid],
                :owner_u    => row[:owner_u],
                :group_u    => row[:group_u],
                :other_u    => row[:other_u])
        end

        @db.run "DROP TABLE old_group_pool;"


        ########################################################################
        #
        # Banner for the new /var/lib/one/vms directory
        #
        ########################################################################

        puts
        puts "ATTENTION: manual intervention required".red
        puts <<-END.gsub(/^ {8}/, '')
        Virtual Machine deployment files have been moved from /var/lib/one to
        /var/lib/one/vms. You need to move these files manually:

            $ mv /var/lib/one/[0-9]* /var/lib/one/vms

        END

        return true
    end


    def set_default_quotas(doc)

        # VM quotas

        doc.root.each_element("VM_QUOTA/VM/CPU") do |e|
            e.text = "-1" if e.text.to_f == 0
        end

        doc.root.each_element("VM_QUOTA/VM/MEMORY") do |e|
            e.text = "-1" if e.text.to_i == 0
        end

        doc.root.each_element("VM_QUOTA/VM/VMS") do |e|
            e.text = "-1" if e.text.to_i == 0
        end

        # VNet quotas

        doc.root.each_element("NETWORK_QUOTA/NETWORK/LEASES") do |e|
            e.text = "-1" if e.text.to_i == 0
        end

        # Image quotas

        doc.root.each_element("IMAGE_QUOTA/IMAGE/RVMS") do |e|
            e.text = "-1" if e.text.to_i == 0
        end

        # Datastore quotas

        doc.root.each_element("DATASTORE_QUOTA/DATASTORE/IMAGES") do |e|
            e.text = "-1" if e.text.to_i == 0
        end

        doc.root.each_element("DATASTORE_QUOTA/DATASTORE/SIZE") do |e|
            e.text = "-1" if e.text.to_i == 0
        end
    end
end
