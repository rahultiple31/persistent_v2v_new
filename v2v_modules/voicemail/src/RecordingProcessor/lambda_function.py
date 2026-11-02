current_version = '2025.09.13'
'''
**********************************************************************************************************************
 *  Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved                                            *
 *                                                                                                                    *
 *  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated      *
 *  documentation files (the "Software"), to deal in the Software without restriction, including without limitation   *
 *  the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and  *
 *  to permit persons to whom the Software is furnished to do so.                                                     *
 *                                                                                                                    *
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO  *
 *  THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE    *
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF         *
 *  CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS *
 *  IN THE SOFTWARE.                                                                                                  *
 **********************************************************************************************************************
'''

# Import required modules
import boto3
import json
import logging
import os
import base64
import io
import urllib.parse
from datetime import datetime
from pydub import AudioSegment

# Logging configuration (level from env var, default INFO)
logger = logging.getLogger()
logger.setLevel(os.environ.get('lambda_logging_level', 'INFO').upper())

# Reuse S3 client across invocations
s3_client = boto3.client('s3')

REQUIRED_VM_ATTRIBUTES = ['vmx3_timestamp', 'vmx3_lang', 'vmx3_queue_arn']


def lambda_handler(event, context):
    logger.info('Code Version: %s', current_version)
    logger.debug(json.dumps(event, default=str))

    processed_records = 0
    skipped_records = 0

    for record in event.get('Records', []):
        try:
            # 1. Process record data
            voicemail_data = process_recording_data(record)

            if voicemail_data is None:
                skipped_records += 1
                continue

            logger.info('********** Step 1 Complete: Record Data Processed **********')

            # 2. Trim audio and save to VMX bucket
            audio_processor(voicemail_data)
            logger.info('********** Step 2 Complete: Record Audio Processed **********')

            processed_records += 1

        except Exception:
            logger.exception('********** Record Processing Failed **********')
            raise

    result = {
        'status': 'complete',
        'processed_records': processed_records,
        'skipped_records': skipped_records
    }
    logger.info('Processing result: %s', json.dumps(result))
    return result


def process_recording_data(record):
    # Decode the Kinesis payload
    try:
        decoded_data = base64.b64decode(record['kinesis']['data'])
        record_data = json.loads(decoded_data.decode('utf-8'))
        logger.debug('Decoded record: %s', json.dumps(record_data, default=str))
    except Exception:
        # Skip non-JSON records instead of blocking the shard with retries
        logger.warning('Skipping record: payload is not valid JSON')
        return None

    contact_id = record_data.get('ContactId', 'Unknown')

    # Only process VMX contacts
    vm_attributes = record_data.get('Attributes') or {}
    if vm_attributes.get('vmx3_flag') != '1':
        logger.info('Skipping ContactId=%s: vmx3_flag is not 1', contact_id)
        return None

    # Recordings may be missing, null, or empty
    recordings = record_data.get('Recordings')
    if not recordings:
        logger.info('Skipping ContactId=%s: no Recordings found', contact_id)
        return None

    # Find the IVR recording
    found_vm = next(
        (r for r in recordings if r.get('ParticipantType') == 'IVR'),
        None
    )
    if found_vm is None:
        logger.info('Skipping ContactId=%s: no IVR recording found', contact_id)
        return None

    logger.info('VM Found for ContactId=%s', contact_id)

    # Validate required attributes
    missing = [k for k in REQUIRED_VM_ATTRIBUTES if not vm_attributes.get(k)]
    if missing:
        raise ValueError(f'ContactId={contact_id} missing VMX attributes: {missing}')

    source_location = found_vm.get('Location')
    source_timestamp = found_vm.get('StartTimestamp')

    if not source_location or '/' not in source_location:
        raise ValueError(f'ContactId={contact_id} invalid recording Location: {source_location}')
    if not source_timestamp:
        raise ValueError(f'ContactId={contact_id} missing recording StartTimestamp')

    vm_attributes.setdefault('vmx3_genai_summary', 'false')
    vm_timestamp = vm_attributes['vmx3_timestamp']

    source_bucket, source_key = source_location.split('/', 1)

    # Date path for the new key
    dt_timestamp = datetime.strptime(vm_timestamp, '%Y-%m-%dT%H:%M:%SZ')

    # Offset between recording start and voicemail start
    ts_vm = datetime.fromisoformat(vm_timestamp.replace('Z', '+00:00'))
    ts_source = datetime.fromisoformat(source_timestamp.replace('Z', '+00:00'))
    vm_offset_seconds = max(0, (ts_vm - ts_source).total_seconds())

    vm_key = f'{dt_timestamp:%Y/%m/%d}/{contact_id}.wav'

    dproc_response = {
        'contact_id': contact_id,
        'vm_attributes': vm_attributes,
        'source_bucket': source_bucket,
        'source_key': source_key,
        'source_timestamp': source_timestamp,
        'vm_timestamp': vm_timestamp,
        'vm_bucket': os.environ['vmx3_recordings_bucket'],
        'vm_key': vm_key,
        'vm_offset': int(vm_offset_seconds * 1000)
    }
    logger.debug(dproc_response)

    return dproc_response


def audio_processor(recording_data):
    # Download recording into memory
    try:
        in_memory_audio = io.BytesIO()
        s3_client.download_fileobj(
            recording_data['source_bucket'],
            recording_data['source_key'],
            in_memory_audio
        )
        in_memory_audio.seek(0)
        logger.debug('********** Loaded audio to buffer **********')
    except Exception:
        logger.exception('********** Could not load audio to buffer **********')
        raise

    # Trim the recording
    try:
        audio_segment = AudioSegment.from_file(in_memory_audio, format='wav')
        vm_audio = audio_segment[recording_data['vm_offset']:]

        out_buffer = io.BytesIO()
        vm_audio.export(out_buffer, format='wav')
        out_buffer.seek(0)
        logger.debug('********** Trimmed recording **********')
    except Exception:
        logger.exception('********** Could not trim audio **********')
        raise

    # Upload trimmed recording with tags
    try:
        attrs = recording_data['vm_attributes']
        vm_tags = {
            'vmx3_lang_value': attrs['vmx3_lang'],
            'vmx3_queue_arn': attrs['vmx3_queue_arn'],
            'vmx3_genai_summary': attrs['vmx3_genai_summary'],
            'vmx3_lang': attrs['vmx3_lang']
        }
        vm_encoded_tags = urllib.parse.urlencode(vm_tags)
        logger.debug(vm_encoded_tags)

        s3_client.upload_fileobj(
            out_buffer,
            recording_data['vm_bucket'],
            recording_data['vm_key'],
            ExtraArgs={'ContentType': 'audio/wav', 'Tagging': vm_encoded_tags}
        )
        logger.info('Saved voicemail to s3://%s/%s',
                    recording_data['vm_bucket'], recording_data['vm_key'])
    except Exception:
        logger.exception('********** Could not upload new file to S3 **********')
        raise