module Admin
  class RulesController < BaseController
    def index
      @rules = Rule.order(priority: :desc, created_at: :desc)
    end

    def new
      @rule = Rule.new
    end

    def create
      @rule = Rule.new(rule_params)
      if @rule.save
        redirect_to admin_rules_path, notice: "Rule created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @rule = Rule.find(params[:id])
    end

    def update
      @rule = Rule.find(params[:id])
      if @rule.update(rule_params)
        redirect_to admin_rules_path, notice: "Rule updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      Rule.find(params[:id]).destroy
      redirect_to admin_rules_path, notice: "Rule deleted."
    end

    private

    def rule_params
      params.require(:rule).permit(:rule_type, :value, :action, :active, :priority, :description)
    end
  end
end
