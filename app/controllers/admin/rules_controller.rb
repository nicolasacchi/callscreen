module Admin
  class RulesController < BaseController
    def index
      @rules = viewing_tenant.rules.order(priority: :desc, created_at: :desc)
    end

    def new
      @rule = viewing_tenant.rules.new
    end

    def create
      @rule = viewing_tenant.rules.new(rule_params)
      if @rule.save
        redirect_to admin_rules_path, notice: "Rule created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @rule = viewing_tenant.rules.find(params[:id])
    end

    def update
      @rule = viewing_tenant.rules.find(params[:id])
      if @rule.update(rule_params)
        redirect_to admin_rules_path, notice: "Rule updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      viewing_tenant.rules.find(params[:id]).destroy
      redirect_to admin_rules_path, notice: "Rule deleted."
    end

    private

    def rule_params
      params.require(:rule).permit(:rule_type, :value, :action, :active, :priority, :description)
    end
  end
end
