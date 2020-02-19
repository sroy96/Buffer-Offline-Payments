require 'sinatra'
require "http"
require 'json'
require "base64"
require 'twilio-ruby'
require "redis"

file = File.read('config.json')
data_hash = JSON.parse(file)

client_id = data_hash['client_id']
client_secret = data_hash['client_secret']

$TWILIO_ACCOUNT_SID = data_hash['twilio']['account_sid']
$TWILIO_AUTH_TOKEN = data_hash['twilio']['auth_token']
$TWILIO_SENDER_NUM = data_hash['twilio']['sender_number']

redis = Redis.new

# call twilio api to send "message" to "to_number"
# reference : https://www.twilio.com/console
def send_twilio_message(to_number, message)
	puts "Sending message to #{to_number}..."

	@client = Twilio::REST::Client.new $TWILIO_ACCOUNT_SID, $TWILIO_AUTH_TOKEN
	@client.account.messages.create({
		:from => $TWILIO_SENDER_NUM,
		:to => to_number,
		:body => message + "\nEnjoy Dove!",
	})
end

# method to check available balance of user
# reference : http://paywithpaytm.com/developer/paytm_api_doc?target=check-balance-api
def check_bal(redis, me)
	sms_message = nil

	check_balance_api_url = 'https://trust-uat.paytm.in/wallet-web/checkBalance'
	me.slice! "+91"
	
	user_token = redis.get("user_tokens:#{me}")
	if user_token
		response = HTTP.headers(:ssotoken => user_token).post(check_balance_api_url)

		if response.code != 200
			puts "Failed Request | #{response.code}"
		else
			json_response = JSON.parse(response.body)
			amount = json_response['response']['amount']
			sms_message = "\nHi!\nYour available wallet balance is : " + amount.to_s + "\n (exclusive of blocked/pre-authorized balance)"
		end
	else
		sms_message = "\nSorry! We don't have any account associated with +91-" + me + "\nSend 'paytm reg <email>' to register your number"
	end
	
	if sms_message
		send_twilio_message("+91" + me, sms_message)
	end
end

# step 1 of registration of a new user
def reg_user(redis, mobile_number, email, client_id)
	sms_message = nil
	
	register_user_api_url = "https://accounts-uat.paytm.com/signin/otp"
	mobile_number.slice! "+91"

	get_state_hash = {
		:email => email,
		:phone => mobile_number,
		:clientId => client_id,
		:scope => 'wallet',
		:responseType => 'token'
	}

	response = HTTP.post(register_user_api_url, :body => get_state_hash.to_json)

	if response.code != 200
		puts "Failed Request | #{response.code}"
	else
		sms_message = "\nFinal Step! Send the OTP received as 'paytm validate <OTP>' from your registered mobile number"
		redis_key = "validate_state:" + mobile_number
		json_response = JSON.parse(response.body)
		redis.set(redis_key, json_response['state'])
	end

	if sms_message
		send_twilio_message("+91" + mobile_number, sms_message)
	end
end

# step 2 of registration of a new user
def validate_user(redis, client_id, client_secret, mobile_number, user_otp)
	sms_message = nil

	validate_user_api_url = "https://accounts-uat.paytm.com/signin/validate/otp"
	mobile_number.slice! "+91"

	basic_auth = "Basic "<<Base64.strict_encode64("#{client_id}:#{client_secret}")
	get_token_hash = {
		:otp => user_otp,
		:state => redis.get("validate_state:#{mobile_number}")
	}
	
	response = HTTP.headers("Authorization" => basic_auth, "Content-Type" => 'application/json').post(validate_user_api_url, :body => get_token_hash.to_json)

	if response.code != 200
		puts "Failed Request | #{response.code}"
	else
		sms_message = "\nCongrats\n You can now use Dove!"
		json_response = JSON.parse(response.body)
		redis.set("user_tokens:#{mobile_number}", json_response["access_token"])
	end

	if sms_message
		send_twilio_message("+91" + mobile_number, sms_message)
	end
end

# method to transfer money to a new number
def send_money(redis, from, to, amt)
	sms_message = nil
	from.slice! "+91"

	query = {
		:request => {
			:isToVerify => 1,
			:isLimitApplicable => 1,
			:payeeEmail => "",
			:payeeMobile => to,
			:payeeCustId => "",
			:amount => amt,
			:currencyCode => "INR",
			:comment => "Loan"
		},
		:ipAddress => "127.0.0.1",
		:platformName => "PayTM",
		:operationType => "P2P_TRANSFER"
	}

	response = HTTP.headers(:ssotoken => redis.get("user_tokens:#{from}")).post('https://trust-uat.paytm.in/wallet-web/wrapper/p2pTransfer', :body => query.to_json)
	if response.code != 200
		puts "Failed Transfer request | #{response}" 
	else
		json_response = JSON.parse(response)
		if json_response['txnStatus'] == "SUCCESS"
			sms_message = json_response['response']['text']
			sms_message_to = "\nHey!\nSuccesfully added INR " + amt.to_s + " from your friend +91-" + from
			send_twilio_message("+91" + to, sms_message_to)	
		else
			sms_message = json_response['response']['text']

		end

	end
	if sms_message
		send_twilio_message("+91" + from, sms_message)
	end
end

get '/' do
	mobile_number = params['from']
	message = params['message']
	mobile_number[0] = '+'
	tokens = message.split()

	if tokens[0].downcase == "dove"
		case tokens[1].downcase
		
		# user wants to send money to a different number
		# dove send | pay <payee number> <amount>
		when 'send', 'pay'
			puts "sending money because obama is no longer prezz"
			to = tokens[2].downcase
			amount = tokens[3].to_i
			send_money(redis, mobile_number, to, amount)

		# user wants to check his/her current available amount
		# dove bal | balance
		when 'balance', 'bal'
			puts "entering balance"
			check_bal(redis, mobile_number)
		
		# user wants to register his/her phone number
		# dove register | reg <email>
		when 'register', 'reg'
			puts "entering registration"
			email = tokens[2].downcase
			reg_user(redis, mobile_number, email, client_id)
		
		# user completes the registration by verifying his/her mobile
		# dove validate <OTP>
		when 'validate'
			puts "entering registration step 2"
			user_otp = tokens[2].downcase
			validate_user(redis, client_id, client_secret, mobile_number, user_otp)
		end
	end

	"Request complete | Long live crime master GOGO | (c) 2017 Dove Evil Inc."
end
