# frozen_string_literal: true

require "hanami/application/view"

RSpec.describe "Application view / Configuration", :application_integration do
  before do
    module TestApp
      class Application < Hanami::Application
        config.root = "/test_app"

        register_slice :main
      end
    end

    Hanami.application.instance_eval(&application_hook) if respond_to?(:application_hook)
    Hanami.application.prepare

    module TestApp
      module View
        class Base < Hanami::Application::View
        end
      end
    end

    module Main
      module View
        class Base < TestApp::View::Base
        end
      end
    end
  end

  let(:view_class) { Main::View::Base }

  subject(:config) { view_class.config }

  it "applies default view configuration from the application" do
    aggregate_failures do
      expect(config.layouts_dir).to eq "layouts"
      expect(config.layout).to eq "application"
    end
  end

  context "custom views configuration on application" do
    let(:application_hook) {
      proc do
        config.views.layouts_dir = "custom_layouts"
        config.views.layout = "my_layout"
      end
    }

    it "applies the custom configuration" do
      aggregate_failures do
        expect(config.layouts_dir).to eq "custom_layouts"
        expect(config.layout).to eq "my_layout"
      end
    end
  end
end
