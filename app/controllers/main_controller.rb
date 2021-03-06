class MainController < ApplicationController

  def index

  end

  def verify_authenticity_token
    (verified_request? || raise(ActionController::InvalidAuthenticityToken)) unless params[:json] == "1"
  end

  def poligraft
    if request.method == "OPTIONS"
      render :nothing => true
      return
    end

    if params[:a_comment_body].blank? && (@result = Result.create!( :source_url => params[:url],
                                                                    :source_text => params[:text],
                                                                    :suppress_text => params[:suppresstext]))
      if params[:textonly] == true
        @result.processed = true
        @result.save
      else
        @result.process_entities
      end

      if params[:json] == "1"
        params[:callback] ? callback = '?callback=' + params[:callback] : callback = ''
        redirect_to "/" + @result.slug + ".json" + callback
      else
        redirect_to "/" + @result.slug
      end

    else
      flash[:error] = "Sorry, couldn't process that input."
      redirect_to :root
    end
  end

  def result
    @result = Result.first(:slug => params[:slug])
    if @result
      response_code = @result.processed ? 200 : 202

      respond_to do |format|
        format.html
        format.json do
          methods = []
          methods << :source_content unless @result.suppress_text
          response = @result.to_json(:methods => methods, :except => [:source_text])
          response = "#{params[:callback]}(#{response})" if params[:callback]
          render :json => response, :status => response_code
        end
      end
    else
      render :file => "#{RAILS_ROOT}/public/404.html", :layout => false, :status => 404
    end
  end

  def feedback

    if params[:feedback]
      @feedback = Feedback.create(params[:feedback])
      if @feedback.save
        Notifier.feedback_email(@feedback).deliver
        redirect_to thanks_path
      else
        flash[:error] = "Error saving. Please fill in all fields."
      end
    else
      @feedback = Feedback.new
    end
  end

  def about

  end

  def plucked
    urls = ['http://www.nytimes.com/2010/05/06/opinion/06gcollins.html',
            'http://www.politico.com/news/stories/0610/38121.html',
            'http://www.theatlantic.com/politics/archive/2010/07/wikileak-ethics/60660/',
            'http://www.cbsnews.com/stories/2010/07/15/politics/main6681481.shtml',
            'http://www.huffingtonpost.com/2010/08/07/theresa-riggi-american-mo_n_674423.html',
            'http://www.latimes.com/business/la-fi-financial-reform-20100716,0,2303004.story',
            'http://www.washingtonpost.com/wp-dyn/content/article/2010/07/30/AR2010073000806.html',
            'http://www.newyorker.com/reporting/2010/08/30/100830fa_fact_mayer?currentPage=all',
            'http://www.bloomberg.com/news/2010-09-14/wal-mart-accused-by-labor-union-farmers-of-suppressing-agriculture-prices.html',
            'http://www.washingtonexaminer.com/politics/_Naked-scanners__-Lobbyists-join-the-war-on-terror-1540901-107548388.html']

    @articles = urls.map { |url| ContentPlucker.pluck_from url }
  end

end
