##########################################################################################
#   Description : Fulfillment lambda for BTSGSD-QueueFlow-Callback bot
#   Invocation : Lex
#   Author : Persistent(197269) , Creation date : 10/05/26 , Last Updated : 10/05/26
##########################################################################################

import json
import logging
import os
import traceback

# Get Log level
loglevel = os.environ.get("LOG_LEVEL")
logger = logging.getLogger()
logger.setLevel(loglevel)

# Setting the lower and upper threshold
lower_threshold = float(os.environ.get("LOWER_THRESHOLD",0.4))
upper_threshold = float(os.environ.get("UPPER_THRESHOLD", 0.7))

#initiating all the prompts and response variables if not exists in session Attributes
def get_session_attributes(event):
    return{
        "menu_prompt":"Please confirm",
        "Global_t_2":"Sorry, I still didn't hear anything",
        "Global_t_1":"Sorry, I didn't hear anything",
        "Global_r_2":"Sorry, I still didn't get that",
        "Global_r_1":"Sorry, I didn't get that",
        "Global_d_2":"My Mistake again",
        "Global_d_1":"My mistake",
        "disconfirm_count": "0",
        "retry_count":"0",
        "timeout_count":"0",
        "confirmation":"yes_confirmation",
    }

def elicit_intent(message):
    '''Function to format response into lex response format for dialogAction - type - ElicitIntent'''
    response = {
        "sessionState":{
            "sessionAttributes": session_attributes,
            "dialogAction": {
                "type": "ElicitIntent",
            },
        },
        "messages": [make_ssml(message)],
    }
    return response

def close(message):
    '''Function to format response into lex response format for dialogAction - type - Close'''
    response = {
        "sessionState":{
            "sessionAttributes": session_attributes,
            "dialogAction": {
                "type": "Close",
            },
            "intent":{
                "confirmationStatus": confirmation_Status,
                "name": intent_name,
                "state":"Fulfilled",
            },
        },
        "messages": [make_ssml(message)],
    }
    return response

def confirm_intent(intent, message, session_attributes):
    '''Function to format response into lex response format for dialogAction - type - Confirm'''
    session_attributes["confirmation_triggered"]="true"
    response = {
        "sessionState":{
            "sessionAttributes": session_attributes,
            "dialogAction": {
                "type": "ConfirmIntent",
            },
            "intent":intent,
        },
        "messages": [make_ssml(message)],
    }
    return response

def timeout():
    '''Handling the Timeout scenarios'''

    session_attributes["timeout1"] = session_attributes["menu_prompt"]
    session_attributes["timeout2"] = session_attributes["menu_prompt"]
    session_attributes["timeout_count"] = int(session_attributes["timeout_count"])+1

    total_count = (
        int(session_attributes["retry_count"]) +
        int(session_attributes["timeout_count"])+
        int(session_attributes["disconfirm_count"]))

    if total_count<3:
        if int(session_attributes["timeout_count"]) == 1:
            input_value = (
                session_attributes["Global_t_1"]+
                "<break time = '0.2s'/>"+
                session_attributes["timeout1"]
            )
            return elicit_intent(input_value)
        elif int(session_attributes["timeout_count"]) == 2:
            input_value = (
                session_attributes["Global_t_2"]+
                "<break time = '0.2s'/>"+
                session_attributes["timeout2"]
            )
            return elicit_intent(input_value)
    else:
        return close("") 

def retry():
    '''Handling the Retry scenarios'''
    session_attributes["retry_count"] = int(session_attributes["retry_count"])+1
    total_count = (
        int(session_attributes["retry_count"]) +
        int(session_attributes["timeout_count"])+
        int(session_attributes["disconfirm_count"]))
    if total_count<3:
        if int(session_attributes["retry_count"]) == 1:
            input_value = (
                session_attributes["Global_r_1"]+
                "<break time = '0.5s'/>"+
                session_attributes["menu_prompt"]
            )
            return elicit_intent(input_value)
        elif int(session_attributes["retry_count"]) == 2:
            input_value = (
                session_attributes["Global_r_2"]+
                "<break time = '0.5s'/>"+
                session_attributes["menu_prompt"]
            )
            return elicit_intent(input_value)
    else:
        return close("")

def disconfirm():
    '''Handling the Disconfirm scenarios'''
    if "disconfirm_count" not in session_attributes:
        session_attributes["disconfirm_count"] = 0
    session_attributes["disconfirm_count"] = int(session_attributes["disconfirm_count"])+1
    total_count = (
        int(session_attributes["retry_count"]) +
        int(session_attributes["timeout_count"])+
        int(session_attributes["disconfirm_count"]))

    if total_count<3:
        if int(session_attributes["disconfirm_count"]) == 1:
            input_value = (
                session_attributes["Global_d_1"]+
                "<break time = '0.5s'/>"+
                session_attributes["menu_prompt"]
            )
            return elicit_intent(input_value)
        elif int(session_attributes["disconfirm_count"]) == 2:
            input_value = (
                session_attributes["Global_d_2"]+
                "<break time = '0.5s'/>"+
                session_attributes["menu_prompt"]
            )
            return elicit_intent(input_value)
    else:
        return close("")

def make_ssml(input_value):
    '''Function to build SSML response'''
    return {
        "contentType": "SSML",
        "content": f"""<speak>{input_value.replace("<speak>","").replace("<speak>","")} </speak>"""
    }

def virtualQueue_handler(intent):
    """Function for handling virtualQueue Intent scenarios """
    session_attributes["confirmation"] = "virtualQueue_confirmation"
    message = ""
    return close(message)

def voicemail_handler(intent):
    """Function for handling voicemail Intent scenarios """
    session_attributes["confirmation"] = "voicemail_confirmation"
    message = ""
    return close(message)

def repeat_handler(intent):
    """Function for handling repeat Intent scenarios """
    session_attributes["confirmation"] = "repeat_confimation"
    message = ""
    return close(message)

def fall_back():
    """Function for handling Fall back Intent scenarios"""

    if 'disconfirm_count' not in session_attributes:
        session_attributes["disconfirm_count"] = 0
    if 'retry_count' not in session_attributes:
        session_attributes["retry_count"] = 0
    if 'timeout_count' not in session_attributes:
        session_attributes["timeout_count"] = 0

    if input_transcript !="":
        return retry()
    else:
        return timeout()

def lambda_handler(event, context):
    global session_attributes, intent_name, confirmation_Status, input_transcript, confidence, contact_id, language
    contact_id = event['sessionId']
    language = event['bot']['localeId']
    logger.debug(f"Event: {json.dumps(event)}")
    logger.info(f"Contact ID: {contact_id}")

    response = {}

    if len(event['sessionState']['sessionAttributes']) > 0:
        session_attributes = event['sessionState']['sessionAttributes']
    else:
        session_attributes = get_session_attributes(event)

    input_transcript = event['inputTranscript']
    logger.debug(f"Input Transcript: {input_transcript} - Contact ID : {contact_id}")

    session_state = event.get('sessionState',{})
    intent = session_state.get('intent', {})
    intent_name = intent["name"]
    logger.debug(f"Intent Name: {intent_name} - Contact ID : {contact_id}")
    confirmation_Status = intent["confirmationState"]

    if "interpretations" in event:
        if intent_name != "FallbackIntent":
            confidence= event["interpretations"][0]["nluConfidence"]
        else:
            confidence = 0

    try:
        session_attributes[f"{intent_name}_count"] = (
            int(session_attributes.get(f"{intent_name}_count", "0")) + 1
        )
    except KeyError:
        logger.debug(f"contact_id: {contact_id} Initializing invocation countsfor intent: {intent_name}")
        session_attributes[f"{intent_name}_count"] = 1

    logger.debug(f"Contact ID: {contact_id} - session_attributes : {session_attributes}")

    try:
        if intent_name=="voicemail":
            response = voicemail_handler(intent)
        elif intent_name=="virtualQueue":
            response = virtualQueue_handler(intent)
        elif intent_name == "repeat":
            response = repeat_handler(intent)
        else:
            response = fall_back()
    except Exception as e:
        logger.error(f"Error in processing the request {str(e)}")
        logger.error(traceback.format_exc())
        raise Exception
    else:
        logger.debug(f"Contact ID: {contact_id} - Response: {response}")
        return response

 