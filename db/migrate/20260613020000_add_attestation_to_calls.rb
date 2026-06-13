class AddAttestationToCalls < ActiveRecord::Migration[8.1]
  # P2-5: STIR/SHAKEN caller-ID attestation, captured from the Telnyx
  # call.initiated webhook when present. Nullable — carrier-forwarded calls
  # (the common Italian path here) usually strip attestation. Used only as a
  # SOFT classifier hint, never a hard block.
  def change
    add_column :calls, :attestation, :string
  end
end
