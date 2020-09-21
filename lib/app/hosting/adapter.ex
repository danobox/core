defmodule App.Hosting.Adapter do
  use App.Schema
  import Ecto.Changeset

  require Logger

  schema "hosting_adapters" do
    belongs_to :user, App.Accounts.User
    field :api, :string
    field :bootstrap_script, :string
    field :can_reboot, :boolean
    field :can_rename, :boolean
    field :default_region, :string
    field :default_size, :string
    field :endpoint, :string
    field :external_iface, :string
    field :global, :boolean, default: false
    field :instructions, :string
    field :internal_iface, :string
    field :name, :string
    field :server_nick_name, :string
    field :ssh_auth_method, :string
    field :ssh_key_method, :string
    field :ssh_user, :string
    field :unlink_code, :string

    many_to_many :teams, App.Accounts.Team, join_through: App.Hosting.TeamAdapter
    has_many :fields, App.Hosting.CredentialField, foreign_key: :hosting_adapter_id
    has_many :regions, App.Hosting.Region, foreign_key: :hosting_adapter_id

    timestamps()
  end

  @doc false
  def changeset(adapter, attrs) do
    adapter
    |> cast(attrs, [:user_id, :global, :endpoint, :unlink_code, :api, :name, :server_nick_name, :default_region, :default_size, :can_reboot, :can_rename, :internal_iface, :external_iface, :ssh_user, :ssh_auth_method, :ssh_key_method, :bootstrap_script, :instructions])
    |> validate_required([:user_id])
    |> foreign_key_constraint(:hosting_credential_fields, name: :hosting_credential_fields_hosting_adapter_id_fkey, message: "Can't delete with child properties")
    |> foreign_key_constraint(:hosting_regions, name: :hosting_regions_hosting_adapter_id_fkey, message: "Can't delete with child properties")
  end

  def generate_unlink_code() do
    :crypto.strong_rand_bytes(30)
    |> Base.url_encode64(padding: false)
  end

  def populate_config(adapter) do
    if adapter.endpoint do
      # First, mark anything we already have in the system as inactive
      adapter = adapter |> App.Repo.preload([:regions])
      Enum.each(adapter.regions, fn (region) ->
        region = region |> App.Repo.preload([:plans])
        Enum.each(region.plans, fn (plan) ->
          plan = plan |> App.Repo.preload([:specs])
          Enum.each(plan.specs, fn (spec) ->
            spec
            |> App.Hosting.Spec.changeset(%{active: false})
            |> App.Repo.update()
          end)
          plan
          |> App.Hosting.Plan.changeset(%{active: false})
          |> App.Repo.update()
        end)
        region
        |> App.Hosting.Region.changeset(%{active: false})
        |> App.Repo.update()
      end)

      # Now, update the adapter with the meta data
      case HTTPoison.get(adapter.endpoint <> "/meta") do
        {:ok, response} ->
          response.body
          |> Poison.decode!()
          |> populate_meta(adapter)
        {:error, err} ->
          Logger.error(adapter.endpoint <> "/meta: " <> Atom.to_string(err.reason))
          false
      end
      |> if do
        # Finally, update the catalog, forcing current options to active again
        case HTTPoison.get(adapter.endpoint <> "/catalog", [], recv_timeout: 120_000) do
          {:ok, response} ->
            response.body
            |> Poison.decode!()
            |> populate_catalog(adapter)
          {:error, err} ->
            Logger.error(adapter.endpoint <> "/catalog: " <> Atom.to_string(err.reason))
        end
      end
    end
  end

  defp populate_meta(meta, adapter) do
    meta_id = meta["id"]
    case adapter.api do
      nil -> true
      ^meta_id -> true
      _else -> false
    end
    |> if do
      changeset(adapter, %{
        api: meta["id"],
        name: meta["name"],
        server_nick_name: meta["server_nick_name"],
        default_region: meta["default_region"],
        default_size: meta["default_size"],
        can_reboot: meta["can_reboot"],
        can_rename: meta["can_rename"],
        internal_iface: meta["internal_iface"],
        external_iface: meta["external_iface"],
        ssh_user: meta["ssh_user"],
        ssh_auth_method: meta["ssh_auth_method"],
        ssh_key_method: meta["ssh_key_method"],
        bootstrap_script: meta["bootstrap_script"],
        instructions: meta["instructions"],
      })
      |> App.Repo.update()

      Enum.each(meta["credential_fields"], fn (field_data) ->
        field = App.Repo.get_by(App.Hosting.CredentialField, [hosting_adapter_id: adapter.id, key: field_data["key"]]) || %App.Hosting.CredentialField{}
        App.Hosting.CredentialField.changeset(field, %{
          hosting_adapter_id: adapter.id,
          key: field_data["key"],
          label: field_data["label"],
        })
        |> App.Repo.insert_or_update()
      end)
      true
    else
      false
    end
  end

  defp populate_catalog(regions, adapter) do
    case regions do
      [{"errors", errors}] ->
        Logger.error(adapter.endpoint <> "/catalog (JSON): " <> Enum.join(errors, " // "))
      regions ->
        Enum.each(regions, fn (region_data) ->
          region = App.Repo.get_by(App.Hosting.Region, [hosting_adapter_id: adapter.id, region: region_data["id"]]) || %App.Hosting.Region{}
          {:ok, db_region} = App.Hosting.Region.changeset(region, %{
            hosting_adapter_id: adapter.id,
            region: region_data["id"],
            name: region_data["name"],
            active: true,
          })
          |> App.Repo.insert_or_update()

          Enum.each(region_data["plans"], fn (plan_data) ->
            plan = App.Repo.get_by(App.Hosting.Plan, [hosting_region_id: db_region.id, plan: plan_data["id"]]) || %App.Hosting.Plan{}
            {:ok, db_plan} = App.Hosting.Plan.changeset(plan, %{
              hosting_region_id: db_region.id,
              plan: plan_data["id"],
              name: plan_data["name"],
              active: true,
            })
            |> App.Repo.insert_or_update()

            Enum.each(plan_data["specs"], fn (spec_data) ->
              spec = App.Repo.get_by(App.Hosting.Spec, [hosting_plan_id: db_plan.id, spec: spec_data["id"]]) || %App.Hosting.Spec{}
              {:ok, _db_spec} = App.Hosting.Spec.changeset(spec, %{
                hosting_plan_id: db_plan.id,
                spec: spec_data["id"],
                ram: spec_data["ram"],
                cpu: spec_data["cpu"],
                disk: spec_data["disk"],
                transfer: case is_float(spec_data["transfer"]) do
                  true -> Kernel.trunc(spec_data["transfer"])
                  false -> case is_integer(spec_data["transfer"]) do
                    true -> spec_data["transfer"]
                    false -> 0
                  end
                end,
                dollars_per_hr: spec_data["dollars_per_hr"],
                dollars_per_mo: spec_data["dollars_per_mo"],
                active: true,
              })
              |> App.Repo.insert_or_update()
            end)
          end)
        end)
    end
  end
end
