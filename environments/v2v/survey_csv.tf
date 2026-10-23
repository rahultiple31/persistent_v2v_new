# Preserve the supplied CSV text; normalize malformed XML attributes after decoding.
locals {
  survey_csv_input_rows = csvdecode(
    trimprefix(
      file("${path.module}/metadata/data-tables/BTSGSD-V2V-US-Survey-DataTable.csv"),
      "\uFEFF"
    )
  )

  survey_csv_normalized_rows = [
    for row in local.survey_csv_input_rows : {
      for column, value in row : column => replace(
        replace(
          replace(
            replace(
              value,
              "interpret-as=“telephone”",
              "interpret-as=\"telephone\""
            ),
            "interpret-as=“ordinal”",
            "interpret-as=\"ordinal\""
          ),
          "<break time = ‘0,2 s’/>",
          "<break time=\"0.2s\"/>"
        ),
        "<break time = ‘0,2s’/>",
        "<break time=\"0.2s\"/>"
      )
    }
  ]

  survey_columns = keys(local.survey_csv_input_rows[0])
  survey_rows = {
    for row in local.survey_csv_normalized_rows : row.Language => row
  }
}
