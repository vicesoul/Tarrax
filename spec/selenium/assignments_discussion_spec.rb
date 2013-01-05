require File.expand_path(File.dirname(__FILE__) + '/common')

describe "discussion assignments" do
  it_should_behave_like "in-process server selenium tests"

  def build_assignment_with_type(text)
    get "/courses/#{@course.id}/assignments"
    driver.execute_script %{$('.header_content .add_assignment_link:first').addClass('focus');}
    f(".header_content .add_assignment_link").click
    wait_for_animations
    click_option(".assignment_submission_types", text)
    submit_form("#add_assignment_form")
    wait_for_ajaximations
  end

  before (:each) do
    course_with_teacher_logged_in
  end

  it "should create a discussion topic when created" do
    build_assignment_with_type("Discussion")
    expect_new_page_load { f("#left-side .discussions").click }
    ff(".discussionTopicIndexList .discussion-topic").should_not be_empty
  end

  it "should redirect to the discussion topic" do
    build_assignment_with_type("Discussion")
    expect_new_page_load { f(".assignment_list .group_assignment .assignment_title a").click }
    driver.current_url.should match %r{/courses/\d+/discussion_topics/\d+}
  end

  it "should create a discussion topic when edited from a regular assignment" do
    build_assignment_with_type("Assignment")
    expect_new_page_load { f(".assignment_list .group_assignment .assignment_title a").click }
    f(".edit_full_assignment_link").click
    wait_for_animations
    click_option(".assignment_type", "Discussion")
    submit_form("#edit_assignment_form")
    wait_for_ajaximations
    expect_new_page_load { f(".assignment_topic_link").click }
    driver.current_url.should match %r{/courses/\d+/discussion_topics/\d+}
  end

  it "should create a discussion topic with requires peer reviews" do
    assignment_title = 'discussion assignment peer reviews'
    get "/courses/#{@course.id}/assignments"
    driver.execute_script %{$('.header_content .add_assignment_link:first').addClass('focus');}
    f(".header_content .add_assignment_link").click
    wait_for_animations
    click_option(".assignment_submission_types", 'Discussion')
    expect_new_page_load { f('.more_options_link').click }
    edit_form = f('#edit_assignment_form')
    keep_trying_until { edit_form.should be_displayed }
    replace_content(edit_form.find_element(:id, 'assignment_title'), assignment_title)
    edit_form.find_element(:id, 'assignment_peer_reviews').click
    submit_form(edit_form)
    wait_for_ajaximations
    expect_new_page_load { f("#assignment_#{Assignment.last.id} .title").click }
    f('.assignment_peer_reviews_link').should be_displayed
  end
end
