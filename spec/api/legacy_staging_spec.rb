# Copyright (c) 2009-2011 VMware, Inc.

require File.expand_path("../spec_helper", __FILE__)

module VCAP::CloudController
  describe VCAP::CloudController::LegacyStaging do
    let(:max_staging_runtime) { 120 }
    let(:cc_addr) { "1.2.3.4" }
    let(:cc_port) { 5678 }
    let(:staging_user) { "user" }
    let(:staging_password) { "password" }
    let(:app_guid) { "abc" }
    let(:staging_config) do
      {
        :max_staging_runtime => max_staging_runtime,
        :bind_address => cc_addr,
        :port => cc_port,
        :staging => {
          :auth => {
            :user => staging_user,
            :password => staging_password
          }
        },
        :resource_pool => {
          :fog_connection => {
            :provider => "Local",
            :local_root => Dir.mktmpdir
          }
        },
        :packages => {
          :fog_connection => {
            :provider => "Local",
            :local_root => Dir.mktmpdir
          }
        },
        :droplets => {
          :fog_connection => {
            :provider => "Local",
            :local_root => Dir.mktmpdir
          }
        }
      }
    end

    before do
      Fog.unmock!
      config_override(staging_config)
      config
    end

    describe "with_upload_handle" do
      it "should yield a handle with an id" do
        LegacyStaging.with_upload_handle(app_guid) do |handle|
          handle.id.should_not be_nil
        end
      end

      it "should yield a handle with the upload_path initially nil" do
        LegacyStaging.with_upload_handle(app_guid) do |handle|
          handle.upload_path.should be_nil
        end
      end

      it "should raise an error if an app guid is staged twice" do
        LegacyStaging.with_upload_handle(app_guid) do |handle|
          expect {
            LegacyStaging.with_upload_handle(app_guid)
          }.to raise_error(Errors::StagingError, /already in progress/)
        end
      end
    end

    describe "app_uri" do
      it "should return a uri to our cc" do
        uri = LegacyStaging.app_uri(app_guid)
        uri.should == "http://#{staging_user}:#{staging_password}@#{cc_addr}:#{cc_port}/staging/apps/#{app_guid}"
      end
    end

    describe "droplet_upload_uri" do
      it "should return a uri to our cc" do
        uri = LegacyStaging.droplet_upload_uri(app_guid)
        uri.should == "http://#{staging_user}:#{staging_password}@#{cc_addr}:#{cc_port}/staging/droplets/#{app_guid}"
      end
    end

    shared_examples "staging bad auth" do |verb|
      it "should return 403 for bad credentials" do
        authorize "hacker", "sw0rdf1sh"
        send(verb, "/staging/apps/#{app_obj.guid}")
        last_response.status.should == 403
      end
    end

    describe "GET /staging/apps/:id" do
      let(:app_obj) { Models::App.make }
      let(:app_obj_without_pkg) { Models::App.make }
      let(:app_package_path) { AppPackage.package_path(app_obj.guid) }

      before do
        config_override(staging_config)
        authorize staging_user, staging_password
      end

      it "should succeed for valid packages" do
        guid = app_obj.guid
        tmpdir = Dir.mktmpdir
        zipname = File.join(tmpdir, "test.zip")
        create_zip(zipname, 10, 1024)
        AppPackage.to_zip(guid, File.new(zipname), [])
        FileUtils.rm_rf(tmpdir)

        get "/staging/apps/#{app_obj.guid}"
        last_response.status.should == 200
      end

      it "should return an error for non-existent apps" do
        get "/staging/apps/#{Sham.guid}"
        last_response.status.should == 404
      end

      it "should return an error for an app without a package" do
        get "/staging/apps/#{app_obj_without_pkg.guid}"
        last_response.status.should == 404
      end

      include_examples "staging bad auth", :get
    end

    describe "POST /staging/droplets/:id" do
      let(:app_obj) { Models::App.make }
      let(:tmpfile) { Tempfile.new("droplet.tgz") }
      let(:upload_req) do
        { :upload => { :droplet => Rack::Test::UploadedFile.new(tmpfile) } }
      end

      before do
        config_override(staging_config)
        authorize staging_user, staging_password
      end

      context "with a valid upload handle" do
        it "should rename the file and store it in handle.upload_path and delete it when the handle goes out of scope" do
          saved_path = nil
          LegacyStaging.with_upload_handle(app_obj.guid) do |handle|
            post "/staging/droplets/#{app_obj.guid}", upload_req
            last_response.status.should == 200
            File.exists?(handle.upload_path).should be_true
            saved_path = handle.upload_path
          end
          File.exists?(saved_path).should be_false
        end
      end

      context "with an invalid upload handle" do
        it "should return an error" do
          post "/staging/droplets/#{app_obj.guid}", upload_req
          last_response.status.should == 400
        end
      end

      context "with an invalid app" do
        it "should return an error" do
          LegacyStaging.with_upload_handle(app_obj.guid) do |handle|
            post "/staging/droplets/bad", upload_req
            last_response.status.should == 404
          end
        end
      end

      include_examples "staging bad auth", :post
    end

    describe "GET /staged_droplets/:id" do
      let(:app_obj) { Models::App.make }

      before do
        config_override(staging_config)
        authorize staging_user, staging_password
      end

      context "with a valid droplet" do
        xit "should return the droplet" do
          droplet = Tempfile.new(app_obj.guid)
          droplet.write("droplet contents")
          droplet.close
          LegacyStaging.store_droplet(app_obj.guid, droplet.path)

          get "/staged_droplets/#{app_obj.guid}"
          last_response.status.should == 200
          last_response.body.should == "droplet contents"
        end

        it "redirects nginx to serve staged droplet" do
          droplet = Tempfile.new(app_obj.guid)
          droplet.write("droplet contents")
          droplet.close
          LegacyStaging.store_droplet(app_obj.guid, droplet.path)

          get "/staged_droplets/#{app_obj.guid}"
          last_response.status.should == 200
          last_response.headers["X-Accel-Redirect"].should match("/cc-droplets/.*/#{app_obj.guid}")
        end
      end

      context "with a valid app but no droplet" do
        it "should return an error" do
          get "/staged_droplets/#{app_obj.guid}"
          last_response.status.should == 400
        end
      end

      context "with an invalid app" do
        it "should return an error" do
          get "/staged_droplets/bad"
          last_response.status.should == 404
        end
      end
    end
  end
end
